import Foundation
import CryptoKit

public enum DiffScope: String, Codable, CaseIterable, Sendable { case working, staged, file }
public enum DiffLayout: String, CaseIterable, Sendable { case stacked, sideBySide }
public enum DiffSide: Sendable { case before, after }
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
/// A multi-file document (every change in Changes) keeps each line's file, so a capture or a
/// hunk action always resolves to that file's own snapshot.
public struct ReviewDocument: Sendable {
    public struct Segment: Sendable {
        public var displayRange: NSRange
        public var contentRange: NSRange
        public var line: DiffLine
        /// Index into `files`.
        public var file: Int = 0
    }
    /// One file's part of the document. Multi-file documents give it a title row, which is not a
    /// segment and so can never be attached.
    public struct FileSection: Sendable {
        public var snapshot: ReviewSnapshot
        public var headerRange: NSRange?
        public var range: NSRange
    }
    public var text: String
    public var segments: [Segment]
    /// The single file's snapshot; for a multi-file document, an identity covering every file.
    public var snapshot: ReviewSnapshot
    public var files: [FileSection]
    public var side: DiffSide?
    public var isMultiFile: Bool { files.count != 1 || files.first?.headerRange != nil }
    public init(source: SourceDocument) {
        text = source.text; segments = source.segments; snapshot = source.snapshot
        files = [FileSection(snapshot: source.snapshot, range: NSRange(location: 0, length: (source.text as NSString).length))]
    }
    /// Every file in order, each under a title row (path and scope) and separated by a blank row.
    /// Files without text lines show their notice, such as a binary change, as a note row.
    public init(files snapshots: [ReviewSnapshot]) {
        var text = "", segments: [Segment] = [], files: [FileSection] = []
        for (index, file) in snapshots.enumerated() {
            let start = (text as NSString).length
            if index > 0 { text += "\n" }
            let headerStart = (text as NSString).length
            let title = file.path + "  ·  " + (file.scope == .staged ? "Staged" : "Unstaged")
            text += title + "\n"
            let header = NSRange(location: headerStart, length: (title as NSString).length + 1)
            var lines = file.lines
            if lines.isEmpty, let notice = file.notice { lines = [DiffLine(id: -1, kind: .header, text: notice)] }
            for line in lines {
                let lineStart = (text as NSString).length
                let prefix = Self.prefix(line)
                text += prefix
                let content = NSRange(location: (text as NSString).length, length: (line.text as NSString).length)
                segments.append(Segment(displayRange: NSRange(location: lineStart, length: NSMaxRange(content) + 1 - lineStart), contentRange: content, line: line, file: index))
                text += line.text + "\n"
            }
            files.append(FileSection(snapshot: file, headerRange: header, range: NSRange(location: start, length: (text as NSString).length - start)))
        }
        let first = snapshots.first
        self.text = text; self.segments = segments; self.files = files
        self.snapshot = ReviewSnapshot(projectID: first?.projectID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, workingDirectory: first?.workingDirectory ?? "",
                                       path: "", scope: first?.scope ?? .working, baseRevision: snapshots.map(\.id).joined(separator: ":"), lines: [])
    }
    private static func prefix(_ line: DiffLine) -> String {
        let old = line.oldLine.map(String.init) ?? ""
        let new = line.newLine.map(String.init) ?? ""
        let marker = line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " "
        return String(format: "%5@ %5@ %@  ", old, new, marker)
    }
    /// The file whose section contains a display offset, including its title row.
    public func file(atUTF16Offset offset: Int) -> Int? {
        var lower = 0, upper = files.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(files[middle].range) <= offset { lower = middle + 1 } else { upper = middle }
        }
        return lower < files.count && NSLocationInRange(offset, files[lower].range) ? lower : nil
    }
    /// The segment index of the `@@` header starting the hunk at a display offset, within the same
    /// file. Title rows, notes and the blank row between files belong to no hunk.
    public func hunkHeader(atUTF16Offset offset: Int) -> Int? {
        guard let file = file(atUTF16Offset: offset), let header = files[file].headerRange.map(NSMaxRange) ?? Optional(files[file].range.location),
              offset >= header else { return nil }
        var lower = 0, upper = segments.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if segments[middle].displayRange.location <= offset { lower = middle + 1 } else { upper = middle }
        }
        var index = lower - 1
        while index >= 0, segments[index].file == file {
            if segments[index].line.kind == .header && segments[index].line.text.hasPrefix("@@") { return index }
            index -= 1
        }
        return nil
    }
    public init(snapshot: ReviewSnapshot) {
        self.snapshot = snapshot
        var text = "", segments: [Segment] = []
        for line in snapshot.lines {
            let start = (text as NSString).length
            text += Self.prefix(line)
            let range = NSRange(location: (text as NSString).length, length: (line.text as NSString).length)
            segments.append(Segment(displayRange: NSRange(location: start, length: NSMaxRange(range) + 1 - start), contentRange: range, line: line))
            text += line.text + "\n"
        }
        self.text = text; self.segments = segments
        files = [FileSection(snapshot: snapshot, range: NSRange(location: 0, length: (text as NSString).length))]
    }
    /// Each change block is paired in source order. Missing counterparts occupy a
    /// display row but have no source segment, so padding can never be attached.
    public static func sideBySide(snapshot: ReviewSnapshot) -> (before: ReviewDocument, after: ReviewDocument) {
        var before: [DiffLine?] = [], after: [DiffLine?] = []
        var deletions: [DiffLine] = [], additions: [DiffLine] = []
        var lastChange: DiffSide?
        func flush() {
            for row in 0..<max(deletions.count, additions.count) {
                before.append(row < deletions.count ? deletions[row] : nil)
                after.append(row < additions.count ? additions[row] : nil)
            }
            deletions.removeAll(keepingCapacity: true); additions.removeAll(keepingCapacity: true)
        }
        for line in snapshot.lines {
            switch line.kind {
            case .deletion: deletions.append(line); lastChange = .before
            case .addition: additions.append(line); lastChange = .after
            case .header where line.text.hasPrefix("\\") && lastChange != nil:
                // Git's missing-newline note belongs to the preceding version.
                if lastChange == .before { deletions.append(line) } else { additions.append(line) }
            case .header, .context:
                flush(); lastChange = nil; before.append(line); after.append(line)
            }
        }
        flush()
        return (ReviewDocument(snapshot: snapshot, rows: before, side: .before),
                ReviewDocument(snapshot: snapshot, rows: after, side: .after))
    }
    private init(snapshot: ReviewSnapshot, rows: [DiffLine?], side: DiffSide) {
        self.snapshot = snapshot; self.side = side
        files = []
        var text = "", segments: [Segment] = [], offset = 0
        for row in rows {
            guard let line = row else { text += "\n"; offset += 1; continue }
            let number = (side == .before ? line.oldLine : line.newLine).map(String.init) ?? ""
            let marker = line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " "
            let prefix = String(format: "%5@ %@  ", number, marker)
            let content = NSRange(location: offset + prefix.utf16.count, length: line.text.utf16.count)
            let display = NSRange(location: offset, length: prefix.utf16.count + content.length + 1)
            segments.append(Segment(displayRange: display, contentRange: content, line: line))
            text += prefix + line.text + "\n"; offset += display.length
        }
        self.text = text; self.segments = segments
        files = [FileSection(snapshot: snapshot, range: NSRange(location: 0, length: offset))]
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
        guard NSLocationInRange(offset, segment.displayRange), segment.line.kind != .header else { return nil }
        let source = NSRange(location: segment.contentRange.location, length: max(1, segment.contentRange.length))
        if selection.location != NSNotFound, selection.length > 0,
           NSIntersectionRange(source, selection).length > 0, attachment(for: selection) != nil {
            return selection
        }
        return source
    }
    /// A selection that crosses into another file captures only the file where it starts.
    public func attachment(for range: NSRange) -> CodeAttachment? {
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= (text as NSString).length else { return nil }
        var chunks: [String] = [], old: [Int] = [], new: [Int] = [], file: Int?
        for segment in segments where segment.line.kind != .header {
            if let file, segment.file != file { continue }
            let overlap = NSIntersectionRange(range, segment.contentRange)
            let selectedEmptyLine = segment.contentRange.length == 0
                && NSLocationInRange(segment.contentRange.location, range)
            guard overlap.length > 0 || selectedEmptyLine else { continue }
            file = segment.file
            chunks.append(selectedEmptyLine ? "" : (text as NSString).substring(with: overlap))
            if let n = segment.line.oldLine { old.append(n) }
            if let n = segment.line.newLine { new.append(n) }
        }
        guard !chunks.isEmpty else { return nil }
        let snapshot = file.flatMap { files.indices.contains($0) ? files[$0].snapshot : nil } ?? self.snapshot
        return CodeAttachment(projectID: snapshot.projectID, workingDirectory: snapshot.workingDirectory, path: snapshot.path,
            snapshotID: snapshot.id, baseRevision: snapshot.baseRevision, scope: snapshot.scope,
            oldLines: old.min().flatMap { low in old.max().map { low...$0 } },
            newLines: new.min().flatMap { low in new.max().map { low...$0 } }, text: chunks.joined(separator: "\n"))
    }
}
