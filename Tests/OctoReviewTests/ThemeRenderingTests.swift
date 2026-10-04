import AppKit
import XCTest
import OctoCore
@testable import OctoReview

final class ThemeRenderingTests: XCTestCase {
    func testDraculaClassicSyntaxAndSelectionPreserveSourceRanges() {
        let doc = document([.init(id: 0, kind: .addition, text: #"let text = "🐙 hello\n"; self.call(42) // comment"#, newLine: 1)])
        let result = NativeDiffView.render(doc, theme: .dracula)
        XCTAssertEqual(result.string, doc.text)
        assertColor(result, "let", "ff79c6")
        assertColor(result, "hello", "f1fa8c")
        assertColor(result, #"\n"#, "f1fa8c")
        assertColor(result, "self", "bd93f9")
        assertColor(result, "call", "50fa7b")
        assertColor(result, "42", "ffb86c")
        assertColor(result, "// comment", "6272a4")
        assertColor(result, "(", "f8f8f2")
        for token in ["self", "// comment"] {
            let index = (result.string as NSString).range(of: token).location
            let font = result.attribute(.font, at: index, effectiveRange: nil) as! NSFont
            XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.italicFontMask))
        }
        let range = (result.string as NSString).range(of: "🐙 hello")
        XCTAssertEqual(doc.attachment(for: range)?.text, "🐙 hello")
        XCTAssertEqual(doc.attachment(for: range)?.newLines, 1...1)
        let json = NativeDiffView.render(document([.init(id: 0, kind: .context, text: #"{"name": "Dracula", "ready": true}"#)], path: "sample.json"), theme: .dracula)
        assertColor(json, "name", "8be9fd")
        assertColor(json, "Dracula", "f1fa8c")
        assertColor(json, "true", "ffb86c")
        XCTAssertEqual(AppTheme.dracula.palette?.selectionBackground, "44475a")
        XCTAssertEqual(AppTheme.dracula.palette?.selectionOpacity, 1)
    }

    func document(_ lines: [DiffLine], path: String = "code.swift") -> ReviewDocument {
        ReviewDocument(snapshot: ReviewSnapshot(projectID: UUID(), workingDirectory: "/tmp/repo", path: path, scope: .working, baseRevision: "abc", lines: lines))
    }
    func assertColor(_ result: NSAttributedString, _ text: String, _ hex: String, file: StaticString = #filePath, line: UInt = #line) {
        let range = (result.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, file: file, line: line)
        guard range.location != NSNotFound else { return }
        XCTAssertEqual(result.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor, NativeDiffView.color(hex, fallback: .labelColor), file: file, line: line)
    }
    func testUnicodeSyntaxDoesNotChangeSourceSelection() {
        let doc = document([.init(id: 0, kind: .addition, text: #"let octo = "🐙 return\n"; call(42) // if comment"#, newLine: 1)])
        for theme in [AppTheme.latte, .mocha] {
            let p = theme.palette!, result = NativeDiffView.render(doc, theme: theme)
            XCTAssertEqual(result.string, doc.text)
            assertColor(result, "let", p.accent)
            assertColor(result, "return", p.green)
            assertColor(result, #"\n"#, p.pink)
            assertColor(result, "call", p.blue)
            assertColor(result, "42", p.peach)
            assertColor(result, "if comment", p.overlay2)
            let range = (result.string as NSString).range(of: "🐙 return")
            XCTAssertEqual(doc.attachment(for: range)?.text, "🐙 return")
            XCTAssertEqual(doc.attachment(for: range)?.newLines, 1...1)
            XCTAssertEqual((result.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor)?.alphaComponent, 0.20)
        }
    }
    func testDiffSidesHaveIndependentCommentStateAndHunksReset() {
        let doc = document([
            .init(id: 0, kind: .deletion, text: "/* removed comment", oldLine: 1),
            .init(id: 1, kind: .addition, text: "let fresh = 2", newLine: 1),
            .init(id: 2, kind: .deletion, text: "return old */", oldLine: 2),
            .init(id: 3, kind: .addition, text: "/* open", newLine: 2),
            .init(id: 4, kind: .header, text: "@@ -10 +10 @@"),
            .init(id: 5, kind: .context, text: "guard ready else { return }", oldLine: 10, newLine: 10)
        ])
        let p = AppTheme.mocha.palette!, result = NativeDiffView.render(doc, theme: .mocha)
        assertColor(result, "let fresh", p.accent)
        assertColor(result, "return old", p.overlay2)
        assertColor(result, "guard ready", p.accent)
        assertColor(result, "@@", p.peach)
    }
    func testMultilineStringsAndPythonDivisionAndJSONKeys() {
        let doc = document([
            .init(id: 0, kind: .context, text: "let text = \"\"\""),
            .init(id: 1, kind: .context, text: "return 🐙"),
            .init(id: 2, kind: .context, text: "\"\"\"; let number = 2")
        ])
        let p = AppTheme.latte.palette!, result = NativeDiffView.render(doc, theme: .latte)
        assertColor(result, "return", p.green)
        assertColor(result, "let number", p.accent)
        let python = NativeDiffView.render(document([.init(id: 0, kind: .context, text: "value = 12 // 3 # return comment")], path: "sample.py"), theme: .latte)
        assertColor(python, "3", p.peach)
        assertColor(python, "return comment", p.overlay2)
        let json = NativeDiffView.render(document([.init(id: 0, kind: .context, text: #"{"name": "return", "count": 42}"#)], path: "sample.json"), theme: .latte)
        assertColor(json, "name", p.blue)
        assertColor(json, "return", p.green)
    }
}
