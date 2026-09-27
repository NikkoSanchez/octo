import XCTest
import OctoCore

final class MarkdownTests: XCTestCase {
    func testBlocksAndInlineFormatting() throws {
        let doc = MarkdownDocument("# Heading\n\nText **bold** and *italic* with `code` and [link](https://example.com).\n- First\n  continuation\n  - Nested\n12. Ordered\n> Quoted\n> second line\n")
        XCTAssertEqual(doc.blocks[0].kind, .heading(1, "Heading"))
        XCTAssertEqual(doc.blocks[3].kind, .listItem(marker: "-", depth: 0, text: "First\ncontinuation"))
        XCTAssertEqual(doc.blocks[4].kind, .listItem(marker: "-", depth: 1, text: "Nested"))
        XCTAssertEqual(doc.blocks[5].kind, .listItem(marker: "12.", depth: 0, text: "Ordered"))
        XCTAssertEqual(doc.blocks[6].kind, .quote("Quoted\nsecond line"))
        let inline = MarkdownInline.parse("**bold** *italic* `code` [link](https://example.com)")
        XCTAssertEqual(String(inline.characters), "bold italic code link")
        XCTAssertTrue(inline.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(inline.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertTrue(inline.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertTrue(inline.runs.contains { $0.link == URL(string: "https://example.com") })
    }

    func testFencesPreserveLiteralCodeAndExactLineEndings() {
        let source = "````swift\r\nlet x = \"**literal**\"\r\n```\r\n~~~~\r\n````\r\nAfter"
        let doc = MarkdownDocument(source)
        XCTAssertEqual(doc.blocks[0].kind, .code(language: "swift", text: "let x = \"**literal**\"\r\n```\r\n~~~~\r\n"))
        XCTAssertEqual(doc.blocks[1].kind, .paragraph("After"))
        XCTAssertEqual(doc.blocks.map(\.source).joined(), source)
        XCTAssertEqual(MarkdownDocument("~~~text\n# literal\n~~~").blocks.first?.kind, .code(language: "text", text: "# literal\n"))
        XCTAssertEqual(MarkdownDocument("```swift\nlet x = 1").blocks.first?.kind, .code(language: "swift", text: "let x = 1"))
        XCTAssertEqual(MarkdownDocument("```swift").blocks.first?.kind, .code(language: "swift", text: ""))
    }

    func testTablesAlignmentEscapesAndMalformedRows() {
        let doc = MarkdownDocument("| Name | Value |\n| :--- | ---: |\n| a\\|b | `x|y` |\n| incomplete\nTail")
        XCTAssertEqual(doc.blocks[0].kind, .table(headers: ["Name", "Value"], alignments: [.leading, .trailing], rows: [["a\\|b", "`x|y`"]]))
        XCTAssertEqual(doc.blocks[1].kind, .paragraph("| incomplete\nTail"))
        XCTAssertEqual(MarkdownDocument("A | B\n:---: | ---\nx | y").blocks[0].kind,
                       .table(headers: ["A", "B"], alignments: [.center, .leading], rows: [["x", "y"]]))
        XCTAssertEqual(MarkdownDocument("A | B\n--- | --").blocks[0].kind, .paragraph("A | B\n--- | --"))
        XCTAssertEqual(MarkdownDocument("| A | B |\n| --- | --- |\n| one | two | extra |").blocks.count, 2)
    }

    func testEveryStreamingPrefixRetainsSourceAndStableBlockIDs() {
        let source = "# Héllo 👩🏽‍💻\n\n**strong** [link](https://example.com)\n\n| A | B |\n| --- | ---: |\n| a | b |\n\n```swift\nlet x = \"💜\"\n```\n> quote\n- item\n"
        for end in source.indices + [source.endIndex] {
            let prefix = String(source[..<end])
            let doc = MarkdownDocument(prefix)
            XCTAssertEqual(doc.source, prefix)
            XCTAssertEqual(doc.blocks.map(\.source).joined(), prefix)
            XCTAssertEqual(Set(doc.blocks.map(\.id)).count, doc.blocks.count)
        }
        XCTAssertEqual(MarkdownDocument("# One\n\nTail").blocks.map(\.id), MarkdownDocument("# One\n\nTail grows").blocks.map(\.id))
    }

    func testIncompleteAndUnsupportedInlineSyntaxStaysVisible() {
        for text in ["**unfinished", "*unfinished", "`unfinished", "[label](https://exam", "[label", "![image](x)", "<b>literal</b>", "\\*literal", "`a*b`", "``a`b``"] {
            let result = MarkdownInline.parse(text)
            if text == "\\*literal" { XCTAssertEqual(String(result.characters), "*literal") }
            else if text == "`a*b`" { XCTAssertEqual(String(result.characters), "a*b") }
            else if text == "``a`b``" { XCTAssertEqual(String(result.characters), "a`b") }
            else { XCTAssertEqual(String(result.characters), text) }
        }
        XCTAssertEqual(String(MarkdownInline.parse("one\ntwo").characters), "one\ntwo")
        XCTAssertEqual(String(MarkdownInline.parse("**bold** with snake_case").characters), "bold with snake_case")
    }

    func testOriginalResponseSurvivesArchiveRoundTrip() throws {
        let source = "# Title\r\n\n```swift\nlet x = 1\n```\n**ending"
        let message = ChatMessage(role: .assistant, text: source)
        _ = MarkdownDocument(message.text)
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message)).text, source)
    }
}

final class TranscriptMetadataTests: XCTestCase {
    func testLocalLinksPreservePathsAndResolveLineReferences() throws {
        let root = "/tmp/project"
        for target in ["/tmp/project/Sources/a.swift:128", "file:///tmp/project/Sources/a.swift#L128", "Sources/a.swift#L128-L130", "Sources/a.swift:128:4"] {
            let link = try XCTUnwrap(MarkdownFileLink(url: XCTUnwrap(URL(string: target)), checkout: root))
            XCTAssertEqual(link.path, "Sources/a.swift")
            XCTAssertEqual(link.line, 128)
        }
        let bare = try XCTUnwrap(MarkdownFileLink(url: XCTUnwrap(URL(string: "README.md:12")), checkout: root))
        XCTAssertEqual(bare.path, "README.md")
        XCTAssertEqual(bare.line, 12)
        let encoded = try XCTUnwrap(MarkdownFileLink(url: XCTUnwrap(URL(string: "Sources/caf%C3%A9%20%2520.swift")), checkout: root))
        XCTAssertEqual(encoded.path, "Sources/café %20.swift", "URL paths must only be decoded once")
        for target in ["../outside.swift", "/tmp/project-other/file", "file://server/tmp/project/a", "https://example.com/a", "javascript:alert(1)", "Sources/a.swift#invalid"] {
            XCTAssertNil(MarkdownFileLink(url: try XCTUnwrap(URL(string: target)), checkout: root), target)
        }
    }
    func testTimingRoundTripLegacyDecodingAndTurnGrouping() throws {
        var user = ChatMessage(role: .user, text: "Question")
        user.work = TurnWork(startedAt: Date(timeIntervalSince1970: 1000))
        user.work?.elapsed = 62; user.work?.outcome = .completed
        let data = try JSONEncoder().encode(user)
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: data), user)
        XCTAssertEqual(user.work?.label, "Worked for 1m 2s")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "work"); legacy.removeValue(forKey: "completedAt")
        XCTAssertNil(try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: legacy)).work)
        let messages = [user, ChatMessage(role: .reasoning, text: "Thinking"), ChatMessage(role: .assistant, text: "Answer"), ChatMessage(role: .user, text: "Next")]
        let turns = ChatTurn.turns(messages)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].details.count, 1)
        XCTAssertEqual(turns[0].responses.map(\.text), ["Answer"])
        XCTAssertEqual(TurnWork.duration(3602), "1h 0m")
        XCTAssertEqual(TurnWork.duration(-2), "0s")
        XCTAssertEqual(TurnWork().label, "Interrupted", "An unfinished saved run must not claim completion")
    }
}
