import XCTest
@testable import OctoCore

final class ChatTurnTests: XCTestCase {
    private func tool(_ name: String, _ state: ToolActivity.State = .completed) -> ChatMessage {
        let activity = ToolActivity(id: UUID().uuidString, server: "Claude", tool: name, state: state)
        var message = ChatMessage(role: .activity, text: activity.text); message.toolActivity = activity
        return message
    }

    func testWorkStaysBetweenTheRepliesItHappenedBetween() {
        let messages = [ChatMessage(role: .user, text: "Fix CI"), ChatMessage(role: .assistant, text: "Checking the logs."),
                        tool("Bash"), tool("Bash"), ChatMessage(role: .reasoning, text: "It needs the CLI"),
                        ChatMessage(role: .assistant, text: "Found it."), tool("Edit"), ChatMessage(role: .assistant, text: "Fixed.")]
        let turn = ChatTurn.turns(messages)[0]
        XCTAssertEqual(turn.body.map(\.isDetails), [false, true, false, true, false])
        XCTAssertEqual(turn.body.filter { !$0.isDetails }.flatMap(\.messages).map(\.text), ["Checking the logs.", "Found it.", "Fixed."])
        XCTAssertEqual(turn.body[1].messages.count, 3)
        XCTAssertEqual(turn.responses.map(\.text), ["Checking the logs.", "Found it.", "Fixed."])
        let imported = ChatTurn.turns([ChatMessage(role: .assistant, text: "Earlier"), tool("Read")])[0]
        XCTAssertNil(imported.user)
        XCTAssertEqual(imported.body.count, 2, "A turn without a user message keeps its first message")
    }

    func testSummariesCountToolsInOrderAndMentionThinking() {
        func summary(_ messages: [ChatMessage]) -> String { ChatMessageGroup.groups(messages)[0].summary }
        XCTAssertEqual(summary([tool("Bash"), tool("Bash"), tool("Bash")]), "Ran 3 commands")
        XCTAssertEqual(summary([ChatMessage(role: .reasoning, text: "Hm"), tool("Read"), tool("Bash"), tool("Read")]),
                       "Thought, read 2 files and ran 1 command")
        XCTAssertEqual(summary([tool("Grep"), tool("Glob"), tool("Edit"), tool("mcp__linear__search")]),
                       "Searched 2 times, edited 1 file and used 1 tool")
        XCTAssertEqual(summary([ChatMessage(role: .activity, text: "git status"), ChatMessage(role: .activity, text: "swift test")]), "2 steps")
        XCTAssertEqual(summary([ChatMessage(role: .activity, text: "")]), "Activity", "An empty placeholder is not counted as work")
        XCTAssertEqual(summary([ChatMessage(role: .reasoning, text: "Hm")]), "Thought")
    }

    func testLiveStatusNamesTheCurrentWork() {
        func status(_ tail: [ChatMessage]) -> String? { ChatTurn.turns([ChatMessage(role: .user, text: "Go")] + tail)[0].liveStatus }
        XCTAssertEqual(status([]), "Thinking", "Before the first event")
        XCTAssertEqual(status([ChatMessage(role: .reasoning, text: "…")]), "Thinking")
        XCTAssertEqual(status([tool("Bash", .running)]), "Running a command")
        XCTAssertEqual(status([tool("Read", .running)]), "Reading a file")
        XCTAssertEqual(status([tool("mcp__browser__click", .running)]), "Using mcp__browser__click")
        XCTAssertEqual(status([tool("Bash")]), "Thinking", "Between tools the agent is deciding what next")
        XCTAssertEqual(status([ChatMessage(role: .activity, text: "swift test --filter Chat\nmore")]), "swift test --filter Chat")
        XCTAssertNil(status([ChatMessage(role: .assistant, text: "Streaming")]), "A streaming reply shows itself")
        var steer = ChatMessage(role: .user, text: "Also this"); steer.isSteering = true
        XCTAssertEqual(status([ChatMessage(role: .assistant, text: "A"), steer]), "Thinking")
    }
}
