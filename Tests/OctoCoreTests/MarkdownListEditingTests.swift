import Foundation
import XCTest
@testable import OctoCore

final class MarkdownListEditingTests: XCTestCase {
    /// `|` marks the caret; `[` and `]` around text mark a selection.
    private func parse(_ marked: String) -> (String, NSRange) {
        var text = marked
        if let caret = text.firstIndex(of: "|") {
            let location = (String(text[..<caret]) as NSString).length
            text.remove(at: caret)
            return (text, NSRange(location: location, length: 0))
        }
        let open = text.firstIndex(of: "«")!; text.remove(at: open)
        let close = text.firstIndex(of: "»")!
        let start = (String(text[..<open]) as NSString).length, end = (String(text[..<close]) as NSString).length
        text.remove(at: close)
        return (text, NSRange(location: start, length: end - start))
    }
    private func apply(_ edit: MarkdownListEditing.Edit?, to text: String) -> String? {
        guard let edit else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        guard edit.selection.length == 0 else { return result }
        return (result as NSString).replacingCharacters(in: edit.selection, with: "|")
    }
    private func newline(_ marked: String) -> String? { let (t, s) = parse(marked); return apply(MarkdownListEditing.newline(in: t, selection: s), to: t) }
    private func indent(_ marked: String) -> String? { let (t, s) = parse(marked); return apply(MarkdownListEditing.indent(in: t, selection: s), to: t) }
    private func outdent(_ marked: String) -> String? { let (t, s) = parse(marked); return apply(MarkdownListEditing.outdent(in: t, selection: s), to: t) }

    func testShiftReturnContinuesBulletsNumbersTasksAndQuotes() {
        XCTAssertEqual(newline("- one|"), "- one\n- |")
        XCTAssertEqual(newline("Intro\n* one|"), "Intro\n* one\n* |")
        XCTAssertEqual(newline("1. one|"), "1. one\n2. |")
        XCTAssertEqual(newline("9) nine|"), "9) nine\n10) |")
        XCTAssertEqual(newline("  - nested|"), "  - nested\n  - |")
        XCTAssertEqual(newline("- [x] done|"), "- [x] done\n- [ ] |")
        XCTAssertEqual(newline("> quoted|"), "> quoted\n> |")
        // Splitting an item carries the rest of the line into the new item.
        XCTAssertEqual(newline("- one| two"), "- one\n- | two")
    }

    func testShiftReturnOnAnEmptyItemEndsOrStepsOutOfTheList() {
        XCTAssertEqual(newline("- one\n- |"), "- one\n|")
        XCTAssertEqual(newline("- one\n- [ ] |"), "- one\n|")
        XCTAssertEqual(newline("> |"), "|")
        XCTAssertEqual(newline("1. one\n   1. |"), "1. one\n2. |")
    }

    func testPlainTextAndCaretsInsideTheMarkerAreLeftToTheTextView() {
        XCTAssertNil(newline("Just text|"))
        XCTAssertNil(newline("-1 is negative|"))
        XCTAssertNil(newline("2.5 is a number|"))
        XCTAssertNil(newline("-| one"))
        XCTAssertFalse(MarkdownListEditing.isInList("Just text", selection: NSRange(location: 4, length: 0)))
        XCTAssertTrue(MarkdownListEditing.isInList("a\n- b", selection: NSRange(location: 4, length: 0)))
        XCTAssertFalse(MarkdownListEditing.isInList("> quote", selection: NSRange(location: 4, length: 0)), "Tab leaves quotes")
    }

    func testTabNestsUnderTheItemAboveAlignedWithItsContent() {
        XCTAssertEqual(indent("- one\n- two|"), "- one\n  - two|")
        XCTAssertEqual(indent("1. one\n2. two|"), "1. one\n   1. two|")
        XCTAssertEqual(indent("1. one\n   1. a\n2. b|"), "1. one\n   1. a\n   2. b|")
        XCTAssertEqual(indent("- one\n- |"), "- one\n  - |")
        // A caret inside the marker lands at the content.
        XCTAssertEqual(indent("- one\n|- two"), "- one\n  - |two")
        // The first item has no parent, and plain lines are not list items.
        XCTAssertNil(indent("- one|"))
        XCTAssertNil(indent("Text\n- one|"))
        XCTAssertNil(indent("one\ntwo|"))
    }

    func testShiftTabMovesOutToTheParentLevelNumberedAfterIt() {
        XCTAssertEqual(outdent("- one\n  - two|"), "- one\n- two|")
        XCTAssertEqual(outdent("1. one\n   1. two|"), "1. one\n2. two|")
        XCTAssertEqual(outdent("- a\n  - b\n    - c|"), "- a\n  - b\n  - c|")
        XCTAssertNil(outdent("- top|"))
    }

    func testTabIndentsEverySelectedItem() {
        let (text, selection) = parse("- one\n«- two\n- three»")
        let edit = try! XCTUnwrap(MarkdownListEditing.indent(in: text, selection: selection))
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        XCTAssertEqual(result, "- one\n  - two\n  - three")
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "  - two\n  - three")
    }

    func testRangesCountUTF16() {
        XCTAssertEqual(newline("- 👋🏽 hi|"), "- 👋🏽 hi\n- |")
        XCTAssertEqual(indent("- 日本\n- 👋🏽|"), "- 日本\n  - 👋🏽|")
    }
}
