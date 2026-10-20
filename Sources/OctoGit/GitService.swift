import Foundation
import Darwin
import OctoCore

public struct ChangedFile: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var path: String
    public var indexStatus: Character
    public var worktreeStatus: Character
    public var isUntracked: Bool { indexStatus == "?" }
    public var hasStaged: Bool { indexStatus != " " && indexStatus != "?" }
    public var hasWorking: Bool { worktreeStatus != " " }
}

public struct DiffStat: Equatable, Sendable {
    public struct Lines: Equatable, Sendable {
        public var additions: Int
        public var deletions: Int
        public init(additions: Int, deletions: Int) { self.additions = additions; self.deletions = deletions }
    }
    public var additions = 0
    public var deletions = 0
    /// Per checkout-relative path. Binary files and renames are counted in the totals only.
    public var files: [String: Lines] = [:]
    public init(additions: Int = 0, deletions: Int = 0, files: [String: Lines] = [:]) {
        self.additions = additions; self.deletions = deletions; self.files = files
    }
}

public actor GitService {
    public init() {}
    private func git(_ arguments: [String], root: String) async throws -> ProcessResult {
        guard let executable = Executables.find("git") else { throw ProcessFailure.missing("git") }
        return try await ProcessRunner.run(executable, arguments: ["--no-optional-locks", "-c", "core.quotepath=false"] + arguments, directory: URL(fileURLWithPath: root))
    }
    private func text(_ arguments: [String], root: String) async throws -> String {
        let result = try await git(arguments, root: root)
        guard result.status == 0 else { throw ProcessFailure.exited(String(decoding: result.error, as: UTF8.self)) }
        return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    public func repositoryRoot(_ path: String) async throws -> String { try await text(["rev-parse", "--show-toplevel"], root: path) }
    public func branch(root: String) async -> String { (try? await text(["branch", "--show-current"], root: root)).flatMap { $0.isEmpty ? nil : $0 } ?? "Detached HEAD" }
    /// Local branches, most recently committed first.
    public func localBranches(root: String) async throws -> [String] {
        try await text(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads"], root: root)
            .split(separator: "\n").map(String.init)
    }
    /// Switches only to an existing local branch; never guesses a remote-tracking branch.
    /// Git's own checks keep uncommitted changes that would be overwritten.
    public func switchBranch(_ name: String, root: String) async throws {
        guard !name.isEmpty, !name.hasPrefix("-") else { throw ProcessFailure.exited("Invalid branch name.") }
        let branches = try await localBranches(root: root)
        guard branches.contains(name) else { throw ProcessFailure.exited("\(name) is not a local branch.") }
        _ = try await text(["switch", "--no-guess", name], root: root)
    }
    /// Lines added and removed in tracked files relative to HEAD (staged and unstaged).
    public func diffStat(root: String) async throws -> DiffStat {
        Self.parseNumstat(try await text(["diff", "--no-ext-diff", "--no-textconv", "--numstat", "HEAD"], root: root))
    }
    public nonisolated static func parseNumstat(_ output: String) -> DiffStat {
        var stat = DiffStat()
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            // Binary files report "-" for both counts.
            let additions = Int(fields[0]), deletions = Int(fields[1])
            stat.additions += additions ?? 0
            stat.deletions += deletions ?? 0
            // Without -z a rename reads "old => new" or "dir/{old => new}"; those paths are not usable.
            if let additions, let deletions, !fields[2].contains(" => ") {
                stat.files[String(fields[2])] = .init(additions: additions, deletions: deletions)
            }
        }
        return stat
    }
    public func changes(root: String) async throws -> [ChangedFile] {
        let result = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], root: root)
        guard result.status == 0 else { throw ProcessFailure.exited(String(decoding: result.error, as: UTF8.self)) }
        return Self.parseStatus(result.output)
    }
    public nonisolated static func parseStatus(_ data: Data) -> [ChangedFile] {
        let records = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true)
        var result: [ChangedFile] = [], i = 0
        while i < records.count {
            let chars = Array(records[i]); i += 1
            guard chars.count >= 4 else { continue }
            result.append(ChangedFile(path: String(chars.dropFirst(3)), indexStatus: chars[0], worktreeStatus: chars[1]))
            if chars[0] == "R" || chars[0] == "C" || chars[1] == "R" || chars[1] == "C" { i += 1 }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    public func filePaths(root: String) async throws -> [String] {
        let result = try await git(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], root: root)
        guard result.status == 0 else { throw ProcessFailure.exited(String(decoding: result.error, as: UTF8.self)) }
        // Cached paths include tracked files deleted from disk; those belong in Changes only.
        let deleted = try await git(["ls-files", "--deleted", "-z"], root: root)
        guard deleted.status == 0 else { throw ProcessFailure.exited(String(decoding: deleted.error, as: UTF8.self)) }
        let missing = Set(String(decoding: deleted.output, as: UTF8.self).split(separator: "\0").map(String.init))
        return Array(Set(String(decoding: result.output, as: UTF8.self).split(separator: "\0").map(String.init)).subtracting(missing)).sorted()
    }
    public func fileSnapshot(path: String, projectID: UUID, root: String) async throws -> ReviewSnapshot {
        let preview = try readPreview(path: path, root: root)
        var lines: [DiffLine] = []
        if let text = preview.text {
            var source = text.components(separatedBy: "\n")
            if source.last == "" { source.removeLast() }
            lines = source.enumerated().map { .init(id: $0.offset, kind: .context, text: $0.element, newLine: $0.offset + 1) }
        }
        let notice = preview.notice
        let base = (try? await text(["rev-parse", "HEAD"], root: root)) ?? "unborn"
        return ReviewSnapshot(projectID: projectID, workingDirectory: root, path: path, scope: .file, baseRevision: base, lines: lines, notice: notice)
    }
    public func snapshot(file: ChangedFile, projectID: UUID, root: String, scope: DiffScope) async throws -> ReviewSnapshot {
        let base = (try? await text(["rev-parse", "HEAD"], root: root)) ?? "unborn"
        var lines: [DiffLine] = [], notice: String?
        if file.isUntracked {
            let preview = try readPreview(path: file.path, root: root)
            notice = preview.notice
            if let text = preview.text {
                lines = text.components(separatedBy: "\n").enumerated().map { .init(id: $0.offset, kind: .addition, text: $0.element, newLine: $0.offset + 1) }
            }
        } else {
            var args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=5"]
            if scope == .staged { args.append("--cached") }
            args += ["--", file.path]
            let result = try await git(args, root: root)
            guard result.status == 0 else { throw ProcessFailure.exited(String(decoding: result.error, as: UTF8.self)) }
            if result.output.count > 2_000_000 { notice = "Diff exceeds the 2 MB preview limit. Open the file in LazyVim." }
            else {
                let patch = String(decoding: result.output, as: UTF8.self)
                lines = UnifiedDiffParser.parse(patch)
                if lines.isEmpty { notice = patch.contains("Binary files") ? "Binary file changed." : "No text changes in this scope (possibly a rename or mode change)." }
            }
        }
        return ReviewSnapshot(projectID: projectID, workingDirectory: root, path: file.path, scope: scope, baseRevision: base, lines: lines, notice: notice)
    }
    /// Walk relative to open directory descriptors; reject symlinks at every level.
    private func readPreview(path: String, root: String) throws -> (text: String?, notice: String?) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ProcessFailure.exited("File path is outside this checkout.")
        }
        var directory = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(directory) }
        for part in parts.dropLast() {
            let next = openat(directory, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ProcessFailure.exited("Cannot preview a missing directory or symbolic-link path.") }
            Darwin.close(directory); directory = next
        }
        let fd = openat(directory, String(parts.last!), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ProcessFailure.exited("Cannot preview a missing file or symbolic link.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return (nil, "This entry is not a regular file.") }
        let limit = 2_000_000
        guard info.st_size <= limit else { return (nil, "This file exceeds the 2 MB preview limit. Open it in LazyVim.") }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &bytes, min(bytes.count, limit + 1 - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            if data.count > limit { return (nil, "This file exceeds the 2 MB preview limit. Open it in LazyVim.") }
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return (nil, "Binary or non-UTF-8 file.") }
        return (text, nil)
    }
}
