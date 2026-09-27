import Foundation
import Darwin

/// A short, owner-only namespace for local IPC; UUID-only names in shared /tmp are insufficient.
public final class PrivateTemporaryDirectory: @unchecked Sendable {
    public let url: URL
    public init() throws {
        var template = Array("/tmp/octo-XXXXXXXX".utf8CString)
        guard let path = mkdtemp(&template) else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        url = URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
