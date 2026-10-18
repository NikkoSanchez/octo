import Foundation
import Darwin

public struct WorkspaceStore: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL.standardizedFileURL }
    public static var standard: WorkspaceStore {
        WorkspaceStore(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Octo/workspace.json"))
    }
    private func prepareDirectory() throws {
        let parent = fileURL.deletingLastPathComponent()
        // An explicit development override must not put conversations inside any checkout.
        var ancestor = parent.resolvingSymlinksInPath()
        while ancestor.path != "/" {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) { throw StoreError.repositoryLocation }
            ancestor.deleteLastPathComponent()
        }
        let exists = FileManager.default.fileExists(atPath: parent.path)
        if !exists { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let fd = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid() else { throw StoreError.unsafeDirectory }
        if !exists || parent == Self.standard.fileURL.deletingLastPathComponent() {
            guard fchmod(fd, 0o700) == 0 else { throw posixError() }
            try excludeBackup(parent)
        } else if (info.st_mode & 0o022) != 0 { throw StoreError.unsafeDirectory }

    }
    private func openArchive() throws -> Int32? {
        let fd = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw posixError() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, fchmod(fd, 0o600) == 0 else {
            Darwin.close(fd); throw StoreError.unsafeFile
        }
        return fd
    }
    private func excludeBackup(_ location: URL? = nil) throws {
        var url = location ?? fileURL
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    public func load() throws -> WorkspaceArchive {
        try prepareDirectory()
        guard let fd = try openArchive() else { return WorkspaceArchive() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try excludeBackup()
        let archive = try JSONDecoder().decode(WorkspaceArchive.self, from: handle.readToEnd() ?? Data())
        guard archive.schemaVersion == 1 else { throw StoreError.unsupportedVersion(archive.schemaVersion) }
        return archive
    }
    /// Persistent per-chat CLI scratch space, separate from repositories and the
    /// archive itself. Descriptor-relative opens refuse substituted symlinks.
    public func prepareChatDirectory(_ id: UUID) throws -> URL {
        try prepareDirectory()
        let parent = fileURL.deletingLastPathComponent()
        var fd = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd) }
        for component in ["ChatWorkspaces", id.uuidString] {
            guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw posixError() }
            let child = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw posixError() }
            var info = stat()
            guard fstat(child, &info) == 0, info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
                Darwin.close(child); throw StoreError.unsafeDirectory
            }
            Darwin.close(fd); fd = child
        }
        let directory = parent.appendingPathComponent("ChatWorkspaces").appendingPathComponent(id.uuidString)
        try excludeBackup(directory)
        return directory
    }
    public func save(_ archive: WorkspaceArchive) throws {
        try prepareDirectory()
        if let existing = try openArchive() { Darwin.close(existing) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        // mkstemp creates mode 0600 before the first sensitive byte is written.
        var template = Array(fileURL.deletingLastPathComponent().appendingPathComponent(".octo-workspace-XXXXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw posixError() }
        let temporary = String(cString: template)
        defer { Darwin.close(fd); unlink(temporary) }
        guard fchmod(fd, 0o600) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw posixError() }
        try excludeBackup(URL(fileURLWithPath: temporary))
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw posixError() }; offset += written
            }
        }
        guard fsync(fd) == 0, rename(temporary, fileURL.path) == 0 else { throw posixError() }
        try excludeBackup()
    }
    private func posixError() -> POSIXError { POSIXError(.init(rawValue: errno) ?? .EIO) }
    public enum StoreError: LocalizedError {
        case unsupportedVersion(Int), repositoryLocation, unsafeFile, unsafeDirectory
        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion: return "This workspace was saved by a newer Octo version. The file has been preserved."
            case .repositoryLocation: return "Conversation storage must be outside Git repositories. Remove OCTO_WORKSPACE_PATH to use private local storage."
            case .unsafeDirectory: return "Workspace storage requires a directory owned by your macOS account that other users cannot modify."
            case .unsafeFile: return "Workspace storage must be a regular, unlinked file owned by your macOS account."
            }
        }
    }
}

/// Encoding and fsyncing the archive takes tens of milliseconds, so debounced saves
/// run on one serial queue. Only the newest pending snapshot is written; snapshots
/// are values, so later main-thread edits never race the encoder.
public final class WorkspaceArchiveWriter: @unchecked Sendable {
    private let storage: WorkspaceStore
    private let queue = DispatchQueue(label: "app.octo.workspace-archive", qos: .utility)
    private let lock = NSLock()
    private var pending: WorkspaceArchive?
    public init(storage: WorkspaceStore) { self.storage = storage }
    /// Returns immediately. `failed` runs on the writer queue.
    public func write(_ archive: WorkspaceArchive, failed: @escaping @Sendable (Error) -> Void) {
        lock.lock()
        let scheduled = pending != nil
        pending = archive
        lock.unlock()
        guard !scheduled else { return }
        queue.async { [self] in
            lock.lock()
            let next = pending; pending = nil
            lock.unlock()
            guard let next else { return }
            do { try storage.save(next) } catch { failed(error) }
        }
    }
    /// Writes after any queued snapshot and supersedes one not yet started.
    public func writeNow(_ archive: WorkspaceArchive) throws {
        try queue.sync {
            lock.lock(); pending = nil; lock.unlock()
            try storage.save(archive)
        }
    }
}
