import Foundation
import Darwin

public enum CheckoutFileError: LocalizedError {
    case unsafePath, unsupportedFile, tooLarge, notText, alreadyExists, changed, readOnly
    public var errorDescription: String? {
        switch self {
        case .unsafePath: return "Choose a relative file path inside this checkout, outside Git metadata. Symbolic links are not supported."
        case .unsupportedFile: return "Only regular files with a single hard link are supported."
        case .tooLarge: return "The native editor supports files up to 2 MB. Open this file in LazyVim."
        case .notText: return "The native editor supports UTF-8 text files. Open this file in another editor."
        case .alreadyExists: return "A file or folder already exists at this path."
        case .changed: return "This file changed on disk. Your edits are still here. Copy any changes you need, then reload the file before saving."
        case .readOnly: return "This file is read-only."
        }
    }
}

/// Captures the checkout and disk identity when an editor or deletion dialog opens.
public struct CheckoutFile: Sendable {
    public let root: String
    public let path: String
    public let text: String?
    fileprivate let data: Data?
    fileprivate let identity: FileIdentity
}

private struct FileIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
    }
}

/// Finite filesystem work runs off MainActor. No shell commands or Git mutations.
public actor CheckoutFileService {
    public init() {}
    public static let editorByteLimit = 2_000_000

    public func inspect(path: String, root: String, forEditing: Bool) throws -> CheckoutFile {
        let (directory, name) = try openParent(path: path, root: root)
        defer { Darwin.close(directory) }
        let fd = try openFile(directory: directory, name: name)
        defer { Darwin.close(fd) }
        let info = try fileInfo(fd)
        let data = forEditing ? try readText(fd, info: info) : nil
        guard try fileInfo(fd).identity == FileIdentity(info) else { throw CheckoutFileError.changed }
        return CheckoutFile(root: root, path: path, text: data.flatMap { String(data: $0, encoding: .utf8) }, data: data, identity: FileIdentity(info))
    }

    public func create(path: String, root: String) throws {
        let (directory, name) = try openParent(path: path, root: root)
        defer { Darwin.close(directory) }
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            if errno == EEXIST { throw CheckoutFileError.alreadyExists }
            throw posixError()
        }
        Darwin.close(fd)
    }

    @discardableResult public func save(_ file: CheckoutFile, text: String) throws -> CheckoutFile {
        let data = Data(text.utf8)
        guard data.count <= Self.editorByteLimit else { throw CheckoutFileError.tooLarge }
        guard !data.contains(0), file.data != nil else { throw CheckoutFileError.notText }
        let (directory, name) = try openParent(path: file.path, root: file.root)
        defer { Darwin.close(directory) }
        let original = try validate(file, directory: directory, name: name)
        guard original.st_mode & 0o222 != 0 else { throw CheckoutFileError.readOnly }
        let temporary = ".octo-save-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd); unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
        guard fchmod(fd, original.st_mode & 0o777) == 0, fsync(fd) == 0 else { throw posixError() }
        // Recheck immediately before replacement; an agent/terminal may have written during the save.
        _ = try validate(file, directory: directory, name: name)
        guard renameat(directory, temporary, directory, name) == 0 else { throw posixError() }
        // Keep the baseline tied to the bytes we wrote, never to a later reader's contents.
        return CheckoutFile(root: file.root, path: file.path, text: text, data: data, identity: FileIdentity(try fileInfo(fd)))
    }

    public func delete(_ file: CheckoutFile) throws {
        let (directory, name) = try openParent(path: file.path, root: file.root)
        defer { Darwin.close(directory) }
        _ = try validate(file, directory: directory, name: name)
        guard unlinkat(directory, name, 0) == 0 else { throw posixError() }
    }

    private func validate(_ file: CheckoutFile, directory: Int32, name: String) throws -> stat {
        let fd = try openFile(directory: directory, name: name)
        defer { Darwin.close(fd) }
        let info = try fileInfo(fd)
        guard FileIdentity(info) == file.identity else { throw CheckoutFileError.changed }
        if let data = file.data {
            guard try readText(fd, info: info) == data, try fileInfo(fd).identity == file.identity else { throw CheckoutFileError.changed }
        }
        var entry = stat()
        guard fstatat(directory, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity(entry) == file.identity else { throw CheckoutFileError.changed }
        return info
    }

    private func openParent(path: String, root: String) throws -> (Int32, String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !path.contains("\0"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else { throw CheckoutFileError.unsafePath }
        var directory = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw posixError() }
        for part in parts.dropLast() {
            let next = openat(directory, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(directory)
            guard next >= 0 else { throw CheckoutFileError.unsafePath }
            directory = next
        }
        return (directory, String(parts.last!))
    }

    private func openFile(directory: Int32, name: String) throws -> Int32 {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        return fd
    }
    private func fileInfo(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw CheckoutFileError.unsupportedFile }
        return info
    }
    private func readText(_ fd: Int32, info: stat) throws -> Data {
        guard info.st_size <= Self.editorByteLimit else { throw CheckoutFileError.tooLarge }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &bytes, min(bytes.count, Self.editorByteLimit + 1 - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw posixError() }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= Self.editorByteLimit else { throw CheckoutFileError.tooLarge }
        }
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { throw CheckoutFileError.notText }
        return data
    }
    private func posixError() -> POSIXError { POSIXError(.init(rawValue: errno) ?? .EIO) }
}

private extension stat {
    var identity: FileIdentity { FileIdentity(self) }
}
