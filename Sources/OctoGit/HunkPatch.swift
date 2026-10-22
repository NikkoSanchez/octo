import Foundation
import OctoCore

/// Rebuilds one displayed hunk as a patch for `git apply --cached`. The patch carries the context
/// that was shown, so Git rejects it if the index has changed since the diff was read.
public enum HunkPatch {
    /// The header line IDs of each `@@` hunk, in display order.
    public static func hunkIDs(in lines: [DiffLine]) -> [Int] {
        lines.filter(isHunkHeader).map(\.id)
    }
    static func isHunkHeader(_ line: DiffLine) -> Bool { line.kind == .header && line.text.hasPrefix("@@") }
    /// The hunk containing a displayed line: the nearest `@@` header at or before it.
    public static func hunkID(containing lineID: Int, in lines: [DiffLine]) -> Int? {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { return nil }
        return lines[...index].last(where: isHunkHeader)?.id
    }
    public static func make(path: String, lines: [DiffLine], hunk id: Int) -> String? {
        guard !path.isEmpty, let start = lines.firstIndex(where: { $0.id == id && isHunkHeader($0) }) else { return nil }
        var body = [lines[start].text], changes = 0
        for line in lines[(start + 1)...] {
            if isHunkHeader(line) { break }
            switch line.kind {
            // Git's "\ No newline at end of file" note belongs to the preceding line.
            case .header: body.append(line.text)
            case .context: body.append(" " + line.text)
            case .addition: body.append("+" + line.text); changes += 1
            case .deletion: body.append("-" + line.text); changes += 1
            }
        }
        guard changes > 0 else { return nil }
        let old = quoted("a/" + path), new = quoted("b/" + path)
        return "diff --git \(old) \(new)\n--- \(old)\n+++ \(new)\n" + body.joined(separator: "\n") + "\n"
    }
    /// Git's C-style quoting, for names with quotes, backslashes or control characters.
    static func quoted(_ name: String) -> String {
        guard name.unicodeScalars.contains(where: { $0 == "\"" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7f }) else { return name }
        // Escaping works on UTF-8 bytes; multibyte characters pass through unchanged.
        return "\"" + String(decoding: escapedBytes(name), as: UTF8.self) + "\""
    }
    private static func escapedBytes(_ name: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for byte in name.utf8 {
            switch byte {
            case UInt8(ascii: "\""): bytes += Array("\\\"".utf8)
            case UInt8(ascii: "\\"): bytes += Array("\\\\".utf8)
            case UInt8(ascii: "\t"): bytes += Array("\\t".utf8)
            case UInt8(ascii: "\n"): bytes += Array("\\n".utf8)
            case UInt8(ascii: "\r"): bytes += Array("\\r".utf8)
            case 0..<0x20, 0x7f: bytes += Array(String(format: "\\%03o", byte).utf8)
            default: bytes.append(byte)
            }
        }
        return bytes
    }
}
