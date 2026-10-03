import Foundation
import CryptoKit

/// Exact editable source and UTF-16 coordinates. Gutters never become document text.
public struct SourceDocument {
    public let text: String
    public let snapshot: ReviewSnapshot
    public let segments: [ReviewDocument.Segment]

    public init(text: String, context: ReviewSnapshot) {
        self.text = text
        let source = text as NSString
        var segments: [ReviewDocument.Segment] = [], offset = 0
        repeat {
            let newline = source.range(of: "\n", range: NSRange(location: offset, length: source.length - offset))
            let end = newline.location == NSNotFound ? source.length : newline.location
            let contentEnd = end > offset && source.character(at: end - 1) == 13 ? end - 1 : end
            let contentRange = NSRange(location: offset, length: contentEnd - offset)
            let line = DiffLine(id: segments.count, kind: .context, text: source.substring(with: contentRange), newLine: segments.count + 1)
            let next = newline.location == NSNotFound ? end : end + 1
            segments.append(.init(displayRange: NSRange(location: offset, length: next - offset), contentRange: contentRange, line: line))
            offset = next
            if newline.location == NSNotFound { break }
        } while offset <= source.length
        self.segments = segments
        var snapshot = ReviewSnapshot(projectID: context.projectID, workingDirectory: context.workingDirectory, path: context.path, scope: .file, baseRevision: context.baseRevision, lines: segments.map(\.line))
        snapshot.id = SHA256.hash(data: Data((snapshot.id + text).utf8)).map { String(format: "%02x", $0) }.joined()
        self.snapshot = snapshot
    }

    public func lineIndex(at offset: Int) -> Int? {
        guard offset >= 0, offset <= (text as NSString).length else { return nil }
        var low = 0, high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].displayRange.location <= offset { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }
    public func attachmentRange(forLineAtUTF16Offset offset: Int, selection: NSRange) -> NSRange? {
        guard let index = lineIndex(at: offset) else { return nil }
        let segment = segments[index]
        if selection.location != NSNotFound, selection.length > 0,
           NSIntersectionRange(segment.displayRange, selection).length > 0 { return selection }
        return segment.contentRange.length > 0 ? segment.contentRange : segment.displayRange
    }
    public func attachment(for range: NSRange) -> CodeAttachment? {
        let length = (text as NSString).length
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= length, range.length <= length - range.location,
              let first = lineIndex(at: range.location), let last = lineIndex(at: NSMaxRange(range) - 1) else { return nil }
        return CodeAttachment(projectID: snapshot.projectID, workingDirectory: snapshot.workingDirectory, path: snapshot.path,
            snapshotID: snapshot.id, baseRevision: snapshot.baseRevision, scope: .file, oldLines: nil,
            newLines: (first + 1)...(last + 1), text: (text as NSString).substring(with: range))
    }
}
