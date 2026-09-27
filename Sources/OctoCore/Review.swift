import Foundation
import CryptoKit

public enum DiffScope: String, Codable, CaseIterable, Sendable { case working, staged, file }
public enum DiffLineKind: String, Codable, Sendable { case context, addition, deletion, header }
public struct DiffLine: Identifiable, Equatable, Sendable {
    public var id: Int
    public var kind: DiffLineKind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?
    public init(id: Int, kind: DiffLineKind, text: String, oldLine: Int? = nil, newLine: Int? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.oldLine = oldLine; self.newLine = newLine
    }
}
public struct ReviewSnapshot: Identifiable, Equatable, Sendable {
    public var id: String
    public var projectID: UUID
    public var workingDirectory: String
    public var path: String
    public var scope: DiffScope
    public var baseRevision: String
    public var lines: [DiffLine]
    public var notice: String?
    public init(projectID: UUID, workingDirectory: String, path: String, scope: DiffScope, baseRevision: String, lines: [DiffLine], notice: String? = nil) {
        self.projectID = projectID; self.workingDirectory = workingDirectory; self.path = path; self.scope = scope
        self.baseRevision = baseRevision; self.lines = lines; self.notice = notice
        let content = workingDirectory + path + scope.rawValue + baseRevision + lines.map { "\($0.kind.rawValue):\($0.oldLine ?? 0):\($0.newLine ?? 0):\($0.text)" }.joined(separator: "\n")
        self.id = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct CodeAttachment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var projectID: UUID
    public var workingDirectory: String
    public var path: String
    public var snapshotID: String
    public var baseRevision: String
    public var scope: DiffScope
    public var oldLines: ClosedRange<Int>?
    public var newLines: ClosedRange<Int>?
    public var text: String
    public var label: String {
        let range = newLines ?? oldLines
        return path + (range.map { ":\($0.lowerBound)–\($0.upperBound)" } ?? "")
    }
    public var promptContext: String {
        """
        <selected_code path="\(path)" scope="\(scope.rawValue)">
        Worktree: \(workingDirectory)
        Snapshot: \(snapshotID); base: \(baseRevision)
        Original lines: \(oldLines.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "none")
        Changed lines: \(newLines.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "none")
        This is a captured selection; verify current file contents before editing.
        \(text)
        </selected_code>
        """
    }
}

/// Maps UTF-16 text selection back to source lines; display gutters never enter prompts.
public struct ReviewDocument: Sendable {
    public struct Segment: Sendable {
        public var displayRange: NSRange
        public var contentRange: NSRange
        public var line: DiffLine
    }
    public var text: String
    public var segments: [Segment]
    public var snapshot: ReviewSnapshot
    public init(snapshot: ReviewSnapshot) {
        self.snapshot = snapshot
        var text = "", segments: [Segment] = []
        for line in snapshot.lines {
            let start = (text as NSString).length
            let old = line.oldLine.map(String.init) ?? ""
            let new = line.newLine.map(String.init) ?? ""
            let marker = line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " "
            let prefix = String(format: "%5@ %5@ %@  ", old, new, marker)
            text += prefix
            let range = NSRange(location: (text as NSString).length, length: (line.text as NSString).length)
            segments.append(Segment(displayRange: NSRange(location: start, length: NSMaxRange(range) + 1 - start), contentRange: range, line: line))
            text += line.text + "\n"
        }
        self.text = text; self.segments = segments
    }
    /// The gutter action uses an existing selection only when hovering one of its source lines.
    /// Otherwise it captures the whole hovered line, including empty source lines.
    public func attachmentRange(forLineAtUTF16Offset offset: Int, selection: NSRange) -> NSRange? {
        guard offset >= 0, offset < (text as NSString).length else { return nil }
        var lower = 0, upper = segments.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(segments[middle].displayRange) <= offset { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower < segments.count else { return nil }
        let segment = segments[lower]
        guard segment.line.kind != .header else { return nil }
        let source = NSRange(location: segment.contentRange.location, length: max(1, segment.contentRange.length))
        if selection.location != NSNotFound, selection.length > 0,
           NSIntersectionRange(source, selection).length > 0, attachment(for: selection) != nil {
            return selection
        }
        return source
    }
    public func attachment(for range: NSRange) -> CodeAttachment? {
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= (text as NSString).length else { return nil }
        var chunks: [String] = [], old: [Int] = [], new: [Int] = []
        for segment in segments where segment.line.kind != .header {
            let overlap = NSIntersectionRange(range, segment.contentRange)
            let selectedEmptyLine = segment.contentRange.length == 0
                && NSLocationInRange(segment.contentRange.location, range)
            guard overlap.length > 0 || selectedEmptyLine else { continue }
            chunks.append(selectedEmptyLine ? "" : (text as NSString).substring(with: overlap))
            if let n = segment.line.oldLine { old.append(n) }
            if let n = segment.line.newLine { new.append(n) }
        }
        guard !chunks.isEmpty else { return nil }
        return CodeAttachment(projectID: snapshot.projectID, workingDirectory: snapshot.workingDirectory, path: snapshot.path,
            snapshotID: snapshot.id, baseRevision: snapshot.baseRevision, scope: snapshot.scope,
            oldLines: old.min().flatMap { low in old.max().map { low...$0 } },
            newLines: new.min().flatMap { low in new.max().map { low...$0 } }, text: chunks.joined(separator: "\n"))
    }
}
