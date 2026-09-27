import Foundation
import OctoCore

public enum UnifiedDiffParser {
    public static func parse(_ patch: String) -> [DiffLine] {
        let expression = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)
        var rows: [DiffLine] = [], old = 0, new = 0, inHunk = false
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(raw)
            if let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                old = Int((text as NSString).substring(with: match.range(at: 1))) ?? 0
                new = Int((text as NSString).substring(with: match.range(at: 2))) ?? 0
                rows.append(.init(id: rows.count, kind: .header, text: text)); inHunk = true
            } else if inHunk, let prefix = text.first {
                switch prefix {
                case "+": rows.append(.init(id: rows.count, kind: .addition, text: String(text.dropFirst()), newLine: new)); new += 1
                case "-": rows.append(.init(id: rows.count, kind: .deletion, text: String(text.dropFirst()), oldLine: old)); old += 1
                case " ": rows.append(.init(id: rows.count, kind: .context, text: String(text.dropFirst()), oldLine: old, newLine: new)); old += 1; new += 1
                case "\\": rows.append(.init(id: rows.count, kind: .header, text: text))
                default: inHunk = false
                }
            }
        }
        return rows
    }
}
