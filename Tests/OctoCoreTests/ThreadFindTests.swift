import Foundation
import XCTest
@testable import OctoCore

final class ThreadFindTests: XCTestCase {
    func testMatchesShownMessagesIgnoringCaseAndAccents() {
        let messages: [ChatMessage] = [
            .init(role: .user, text: "Please fix the Café menu"),
            .init(role: .activity, text: "rg cafe Sources/"),
            .init(role: .reasoning, text: "The cafe view is broken"),
            .init(role: .assistant, text: "Fixed the **cafe** layout."),
            .init(role: .error, text: "CAFÉ failed to build")
        ]
        XCTAssertEqual(ThreadFind.matches("cafe", in: messages), [messages[0].id, messages[3].id, messages[4].id],
                       "Collapsed activity and reasoning are not searched")
        XCTAssertEqual(ThreadFind.matches("  ", in: messages), [])
        XCTAssertEqual(ThreadFind.matches(" menu ", in: messages), [messages[0].id], "Surrounding spaces are trimmed")
    }

    func testRangesFindEveryOccurrence() {
        let text = "Go to 👋🏽 go GO, gopher"
        let found = ThreadFind.ranges(of: "go", in: text).map { String(text[$0]) }
        XCTAssertEqual(found, ["Go", "go", "GO", "go"])
        XCTAssertEqual(ThreadFind.ranges(of: "aa", in: "aaaa").count, 2, "Occurrences do not overlap")
        XCTAssertTrue(ThreadFind.ranges(of: "", in: text).isEmpty)
    }
}
