import XCTest
import OctoCore

final class ThreadPreviewTests: XCTestCase {
    func testMarkdownReducesToOneReadableLine() {
        let markdown = "## Found it\n\n> `SidebarObservation` republished on **every** store tick.\n\n```swift\nlet hidden = true\n```\n- Coalesced to [one diff](https://example.com) per run loop\n2. Idle CPU is *back* to 0%."
        XCTAssertEqual(ThreadPreview.plain(markdown),
                       "Found it SidebarObservation republished on every store tick. Coalesced to one diff per run loop Idle CPU is back to 0%.")
        XCTAssertEqual(ThreadPreview.plain("```\nonly code\n```"), "")
        XCTAssertEqual(ThreadPreview.plain("3 files changed"), "3 files changed", "Numbers without a list marker stay")
    }

    func testLongRepliesAreTruncatedAndOnlyTheirHeadIsRead() {
        let preview = ThreadPreview.plain(String(repeating: "word ", count: 2_000))
        XCTAssertEqual(preview.count, 160)
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    func testPreviewUsesTheNewestReplyOrTheUsersUnansweredMessage() {
        var thread = WorkspaceThread(title: "Fixture", workingDirectory: "/tmp")
        XCTAssertNil(ThreadPreview.text(thread))
        thread.messages = [.init(role: .user, text: "Can tabs survive a relaunch?")]
        XCTAssertEqual(ThreadPreview.text(thread), "You: Can tabs survive a relaunch?")
        thread.messages.append(.init(role: .assistant, text: "Done. **Tabs** persist per project."))
        thread.messages.append(.init(role: .activity, text: "Edited 4 files"))
        XCTAssertEqual(ThreadPreview.text(thread), "Done. Tabs persist per project.", "Tool activity is not a message")
    }
}
