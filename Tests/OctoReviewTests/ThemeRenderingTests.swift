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
            let s = theme.syntax!, result = NativeDiffView.render(doc, theme: theme)
            XCTAssertEqual(result.string, doc.text)
            assertColor(result, "let", s.keyword)
            assertColor(result, "return", s.string)
            assertColor(result, #"\n"#, s.escape)
            assertColor(result, "call", s.function)
            assertColor(result, "42", s.number)
            assertColor(result, "if comment", s.comment)
            let range = (result.string as NSString).range(of: "🐙 return")
            XCTAssertEqual(doc.attachment(for: range)?.text, "🐙 return")
            XCTAssertEqual(doc.attachment(for: range)?.newLines, 1...1)
            XCTAssertEqual((result.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor)?.alphaComponent, 0.15)
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
        let s = AppTheme.mocha.syntax!, result = NativeDiffView.render(doc, theme: .mocha)
        assertColor(result, "let fresh", s.keyword)
        assertColor(result, "return old", s.comment)
        assertColor(result, "guard ready", s.keyword)
        assertColor(result, "@@", s.hunk)
    }
    func testMultilineStringsAndPythonDivisionAndJSONKeys() {
        let doc = document([
            .init(id: 0, kind: .context, text: "let text = \"\"\""),
            .init(id: 1, kind: .context, text: "return 🐙"),
            .init(id: 2, kind: .context, text: "\"\"\"; let number = 2")
        ])
        let s = AppTheme.latte.syntax!, result = NativeDiffView.render(doc, theme: .latte)
        assertColor(result, "return", s.string)
        assertColor(result, "let number", s.keyword)
        let python = NativeDiffView.render(document([.init(id: 0, kind: .context, text: "value = 12 // 3 # return comment")], path: "sample.py"), theme: .latte)
        assertColor(python, "3", s.number)
        assertColor(python, "return comment", s.comment)
        let json = NativeDiffView.render(document([.init(id: 0, kind: .context, text: #"{"name": "return", "count": 42}"#)], path: "sample.json"), theme: .latte)
        assertColor(json, "name", s.key)
        assertColor(json, "return", s.string)
    }
    /// Catppuccin roles from the style guide and the official VS Code port, against palette 1.8.0 values.
    func testCatppuccinStyleGuideRoles() {
        let latte = AppTheme.latte.palette!, mocha = AppTheme.mocha.palette!
        XCTAssertEqual([latte.base, latte.mantle, latte.surface, latte.text, latte.secondary, latte.overlay1, latte.cursor, latte.activeBorder],
                       ["eff1f5", "e6e9ef", "ccd0da", "4c4f69", "6c6f85", "8c8fa1", "dc8a78", "7287fd"])
        XCTAssertEqual(latte.cursorText, latte.base)
        XCTAssertEqual(mocha.cursorText, "11111b")
        for theme in [AppTheme.latte, .frappe, .macchiato, .mocha] {
            let p = theme.palette!
            XCTAssertEqual(p.selectionOpacity, theme == .latte ? 0.30 : 0.25)
            XCTAssertEqual(p.selectionBackground, p.overlay2)
            XCTAssertEqual(p.ansi.count, 18)
            // VS Code port: list selection Surface0 with Text, on-accent Crust, line highlight 7%, diff lines 15%.
            XCTAssertEqual(p.listSelection, p.surface)
            XCTAssertEqual(p.listSelectionText, p.text)
            XCTAssertEqual(p.onAccent, theme.palette!.crust)
            XCTAssertEqual(p.lineHighlightOpacity, 0.07)
            XCTAssertEqual(p.diffLineOpacity, 0.15)
            XCTAssertEqual(p.findCurrent, p.red)
        }
        XCTAssertEqual([latte.terminalSelectionBackground, mocha.terminalSelectionBackground], ["acb0be", "585b70"])
        XCTAssertEqual([latte.findOther, mocha.findOther], ["04a5e5", "89dceb"])
        XCTAssertEqual(AppTheme.frappe.palette!.cursorText, "232634")
        XCTAssertEqual(AppTheme.macchiato.palette!.ansi[16...], ["f5a97f", "f4dbd6"])
        let s = AppTheme.mocha.syntax!
        XCTAssertEqual([s.keyword, s.string, s.escape, s.comment, s.number, s.function, s.key, s.punctuation, s.operatorColor, s.builtin],
                       ["cba6f7", "a6e3a1", "f5c2e7", "9399b2", "fab387", "89b4fa", "89b4fa", "9399b2", "94e2d5", "f38ba8"])
        XCTAssertEqual(s.italic, [.comment, .function])
        let result = NativeDiffView.render(document([.init(id: 0, kind: .context, text: "self.run(this)")], path: "a.swift"), theme: .mocha)
        assertColor(result, "self", "f38ba8")
        let font = result.attribute(.font, at: (result.string as NSString).range(of: "run").location, effectiveRange: nil) as! NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.italicFontMask))
        // Other themes keep their accent row selection and Base on-accent text.
        XCTAssertEqual(AppTheme.dracula.palette!.listSelection, "bd93f9")
        XCTAssertEqual(AppTheme.tokyoNight.palette!.onAccent, "1a1b26")
        XCTAssertNil(AppTheme.dracula.palette!.findCurrent)
    }
    func testEveryThemeHasCompletePalettesAndRendersStably() {
        let doc = document([.init(id: 0, kind: .addition, text: #"let x = "🐙\n" // note"#, newLine: 1)])
        for theme in AppTheme.allCases where theme != .system {
            let p = theme.palette!, s = theme.syntax!
            let colors = [p.base, p.mantle, p.crust, p.surface, p.overlay0, p.overlay1, p.overlay2, p.text, p.secondary,
                          p.accent, p.green, p.red, p.yellow, p.blue, p.teal, p.orange, p.activeBorder, p.cursor, p.cursorText,
                          p.selectionBackground, p.terminalSelectionBackground, p.lineHighlight, s.keyword, s.string, s.escape,
                          s.comment, s.number, s.function, s.key, s.punctuation, s.operatorColor, s.builtin, s.hunk, s.diffFile, s.diffPath] + p.ansi
            XCTAssertTrue(colors.allSatisfy { $0.count == 6 && UInt32($0, radix: 16) != nil }, theme.title)
            XCTAssertTrue([16, 18].contains(p.ansi.count), theme.title)
            XCTAssertLessThan(p.lineHighlightOpacity, 1, theme.title)
            let result = NativeDiffView.render(doc, theme: theme)
            XCTAssertEqual(result.string, doc.text, theme.title)
            assertColor(result, "let", s.keyword)
        }
        XCTAssertEqual(Set(AppTheme.allCases.map(\.title)).count, AppTheme.allCases.count)
        XCTAssertNil(AppTheme.system.isDark)
        XCTAssertEqual(AppTheme.allCases.filter { $0.isDark == false }.count, 7)
        // Translucent selections are precomposed for the terminal's opaque setting.
        XCTAssertEqual(ThemePalette.composite("ffffff", opacity: 0.5, over: "000000"), "808080")
        XCTAssertEqual(AppTheme.githubDark.palette!.terminalSelectionBackground, "17335a")
    }
}
