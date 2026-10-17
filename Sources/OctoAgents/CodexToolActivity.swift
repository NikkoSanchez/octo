import Foundation
import OctoCore

/// Never renders arguments, auth metadata, binary payloads, or embedded app resources.
/// Redaction is defensive, not a guarantee against secrets in arbitrary tool prose.
enum AgentToolDetails {
    static func text(_ text: String, limit: Int = 8192) -> String {
        var value = String(text.prefix(32768))
        for (index, pattern) in [#"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#,
                        #"(?i)((?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|secret|authorization)\s*[\"']?\s*[:=]\s*[\"']?)[^\s,\"'}]+"#,
                        #"\b(sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{16,})\b"#].enumerated() {
            value = value.replacingOccurrences(of: pattern, with: index < 2 ? "$1[redacted]" : "[redacted]", options: .regularExpression)
        }
        return String(value.prefix(limit)) + (value.count > limit || text.count > 32768 ? "\n[truncated]" : "")
    }
    static func result(_ item: [String: Any]) -> String {
        if let error = item["error"] as? [String: Any], let message = error["message"] as? String { return text(message) }
        guard let result = item["result"] as? [String: Any] else { return "" }
        var parts: [String] = []
        for block in (result["content"] as? [[String: Any]] ?? []).prefix(16) {
            if block["type"] as? String == "text", let value = block["text"] as? String { parts.append(text(value)) }
            else { parts.append("[Non-text result omitted]") }
        }
        if let structured = result["structuredContent"], !(structured is NSNull),
           let data = try? JSONSerialization.data(withJSONObject: sanitize(structured, depth: 0), options: [.sortedKeys, .fragmentsAllowed]), let value = String(data: data, encoding: .utf8) { parts.append(text(value)) }
        return text(parts.joined(separator: "\n"))
    }
    private static func sanitize(_ value: Any, depth: Int) -> Any {
        guard depth < 5 else { return "[nested result omitted]" }
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            for key in object.keys.sorted().prefix(32) {
                if key.range(of: "token|secret|password|credential|authorization|cookie|api.?key|_meta", options: [.regularExpression, .caseInsensitive]) != nil { result[key] = "[redacted]" }
                else { result[text(key, limit: 128)] = sanitize(object[key]!, depth: depth + 1) }
            }
            return result
        }
        if let array = value as? [Any] { return array.prefix(16).map { sanitize($0, depth: depth + 1) } }
        if let string = value as? String { return text(string, limit: 2048) }
        return value
    }
}
