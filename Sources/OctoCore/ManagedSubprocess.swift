import Foundation
import Darwin

/// Owns a process group and bounded, nonblocking pipes. Callbacks run on one background queue.
/// Descendants which deliberately create another session are outside this lifecycle boundary.
public final class ManagedSubprocess: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var closeRequested = false
    private var stopping = false
    private var interruptRequested = false
    private var finished = false
    private let pid: pid_t
    private let input: Int32
    private let output: Int32
    private let error: Int32
    private let queueLimit = 36 * 1_024 * 1_024

    private init(pid: pid_t, input: Int32, output: Int32, error: Int32) {
        self.pid = pid; self.input = input; self.output = output; self.error = error
    }
    public var running: Bool { lock.lock(); defer { lock.unlock() }; return !finished && !stopping }
    public func send(_ data: Data, closeInput: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished && !stopping && !closeRequested else { throw ProcessFailure.exited("Agent process is not accepting input.") }
        guard data.count <= queueLimit - pending.count else { throw ProcessFailure.oversized }
        pending.append(data); closeRequested = closeInput
    }
    public func stop() { lock.lock(); stopping = true; lock.unlock() }
    public func interrupt() { lock.lock(); interruptRequested = true; lock.unlock() }

    public static func launch(executable: URL, arguments: [String], directory: URL,
                              environment: [String: String], timeout: TimeInterval? = nil,
                              outputLimit: Int? = nil,
                              onOutput: @escaping @Sendable (Data) -> Void,
                              onError: @escaping @Sendable (Data) -> Void,
                              onExit: @escaping @Sendable (Int32, Error?) -> Void) throws -> ManagedSubprocess {
        guard !([executable.path, directory.path] + arguments + environment.flatMap { [$0.key, $0.value] }).contains(where: { $0.contains("\0") }) else {
            throw ProcessFailure.exited("Process arguments and environment must not contain NUL bytes.")
        }
        var pipes: [Int32] = []
        defer { pipes.forEach { Darwin.close($0) } }
        for _ in 0..<3 {
            var pair: [Int32] = [0, 0]
            guard pipe(&pair) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            pipes += pair
            for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        func check(_ code: Int32) throws { if code != 0 { throw POSIXError(.init(rawValue: code) ?? .EIO) } }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        for (fd, target) in [(pipes[0], STDIN_FILENO), (pipes[3], STDOUT_FILENO), (pipes[5], STDERR_FILENO)] {
            try check(posix_spawn_file_actions_adddup2(&actions, fd, target))
        }
        for fd in pipes { try check(posix_spawn_file_actions_addclose(&actions, fd)) }
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var signals = sigset_t(); sigemptyset(&signals)
        try check(posix_spawnattr_setsigmask(&attributes, &signals))
        sigaddset(&signals, SIGPIPE); sigaddset(&signals, SIGTERM); sigaddset(&signals, SIGINT)
        try check(posix_spawnattr_setsigdefault(&attributes, &signals))
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let code = argv.withUnsafeBufferPointer { a in envp.withUnsafeBufferPointer { e in
            posix_spawn(&pid, executable.path, &actions, &attributes, a.baseAddress!, e.baseAddress!)
        } }
        try check(code)
        let process = ManagedSubprocess(pid: pid, input: pipes[1], output: pipes[2], error: pipes[4])
        for fd in [pipes[1], pipes[2], pipes[4]] { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
        // A closed child stdin must produce EPIPE, never terminate Octo.
        _ = fcntl(pipes[1], F_SETNOSIGPIPE, 1)
        pipes = [pipes[0], pipes[3], pipes[5]]
        DispatchQueue.global(qos: .utility).async {
            process.pump(timeout: timeout, outputLimit: outputLimit, onOutput: onOutput, onError: onError, onExit: onExit)
        }
        return process
    }

    private func pump(timeout: TimeInterval?, outputLimit: Int?, onOutput: (Data) -> Void,
                      onError: (Data) -> Void, onExit: (Int32, Error?) -> Void) {
        let start = ProcessInfo.processInfo.systemUptime
        var stopAt: TimeInterval?, writeAt: TimeInterval?, exitAt: TimeInterval?
        var failure: Error?, total = 0, status: Int32 = 0
        var inputOpen = true, outputOpen = true, errorOpen = true, childExited = false
        var bytes = [UInt8](repeating: 0, count: 16_384)
        defer {
            if inputOpen { Darwin.close(input) }; if outputOpen { Darwin.close(output) }; if errorOpen { Darwin.close(error) }
        }
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock()
            if interruptRequested { if !childExited { Darwin.kill(-pid, SIGINT) }; interruptRequested = false }
            if !pending.isEmpty && writeAt == nil { writeAt = now }
            if inputOpen && !pending.isEmpty {
                let count = pending.withUnsafeBytes { Darwin.write(input, $0.baseAddress, min($0.count, 16_384)) }
                if count > 0 { pending.removeFirst(count); writeAt = pending.isEmpty ? nil : now }
                else if count < 0 && errno != EAGAIN && errno != EINTR {
                    failure = ProcessFailure.exited("Process input pipe closed."); stopping = true
                }
            }
            if inputOpen && closeRequested && pending.isEmpty { Darwin.close(input); inputOpen = false }
            let shouldStop = stopping
            lock.unlock()
            if timeout.map({ now - start >= $0 }) == true && failure == nil { failure = ProcessFailure.timedOut }
            if writeAt.map({ now - $0 >= 15 }) == true && failure == nil { failure = ProcessFailure.exited("Process input timed out.") }
            if (shouldStop || failure != nil) && stopAt == nil {
                stopAt = now; Darwin.kill(-pid, SIGTERM)
            }
            if let stopAt, now - stopAt >= 0.3 { Darwin.kill(-pid, SIGKILL) }
            for stream in 0..<2 {
                guard stream == 0 ? outputOpen : errorOpen else { continue }
                let fd = stream == 0 ? output : error
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 {
                    if let outputLimit, count > outputLimit - total { failure = ProcessFailure.oversized }
                    else if failure == nil { total += outputLimit == nil ? 0 : count; (stream == 0 ? onOutput : onError)(Data(bytes.prefix(count))) }
                } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                    Darwin.close(fd); if stream == 0 { outputOpen = false } else { errorOpen = false }
                }
            }
            if !childExited {
                // Observe without reaping: the PID/group cannot be recycled before cleanup signals.
                var info = siginfo_t()
                if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid {
                    childExited = true; exitAt = now
                    Darwin.kill(-pid, SIGKILL)
                }
            }
            if childExited && ((!outputOpen && !errorOpen) || now - (exitAt ?? now) > 0.5) { break }
            var descriptors = [pollfd(fd: outputOpen ? output : -1, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: errorOpen ? error : -1, events: Int16(POLLIN), revents: 0)]
            _ = poll(&descriptors, nfds_t(descriptors.count), 10)
        }
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        lock.lock(); finished = true; pending.removeAll(); lock.unlock()
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        onExit(exitCode, failure)
    }
}
