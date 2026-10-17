import XCTest
import OctoCore
@testable import OctoAgents

@MainActor final class AgentCommandTests: XCTestCase {
    func testCodexSkillsListAndExplicitTurnInputWithoutChangingPermissions() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scripts/fixtures/codex-skills.py")
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let commands = try await CodexHarness.commands(directory: directory, executable: fixture)
        XCTAssertEqual(commands.map(\.name), ["fixture-review"])
        let harness = CodexHarness(executable: fixture)
        defer { harness.shutdown() }
        let finished = expectation(description: "Skill turn finished")
        harness.onEvent = { event in
            if case .finished = event { finished.fulfill() }
            if case .failed(let error) = event { XCTFail(error) }
        }
        try await harness.send(prompt: "/fixture-review explain", sessionID: nil, directory: directory, settings: .init(), images: [])
        await fulfillment(of: [finished], timeout: 5)
    }
    func testCodexRejectsWrongCheckoutAndDisabledSkillsAndPreservesArguments() throws {
        let skills: [[String: Any]] = [["name": "review", "enabled": true, "path": "/tmp/fixture/SKILL.md"],
                                    ["name": "hidden", "enabled": false, "path": "/tmp/hidden/SKILL.md"],
                                    ["name": "bad", "enabled": true, "path": "relative/SKILL.md"]]
        let response: [String: Any] = ["data": [["cwd": "/tmp", "skills": skills]]]
        let commands = try CodexHarness.decodeCommands(response, directory: "/tmp")
        XCTAssertEqual(commands.map(\.name), ["review"])
        XCTAssertThrowsError(try CodexHarness.decodeCommands(response, directory: "/different"))
        let input = CodexHarness.commandInput(prompt: "/review explain\n\nCaptured context", commands: commands)
        XCTAssertEqual(input[0]["text"] as? String, "$review explain\n\nCaptured context")
        XCTAssertEqual(input[1]["type"] as? String, "skill")
        XCTAssertEqual(input[1]["path"] as? String, "/tmp/fixture/SKILL.md")
        XCTAssertEqual(CodexHarness.commandInput(prompt: "hello /review", commands: commands).count, 1)
        XCTAssertEqual(CodexHarness.commandInput(prompt: "/unknown", commands: commands)[0]["text"] as? String, "/unknown")
    }
    func testCodexSkillSteeringUsesCapturedTurnAndDoesNotOverridePermissions() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scripts/fixtures/codex-skills.py")
        let harness = CodexHarness(executable: fixture)
        defer { harness.shutdown() }
        try await harness.send(prompt: "/fixture-review hold", sessionID: nil,
                               directory: FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path, settings: .init(), images: [])
        try await harness.steer(prompt: "/fixture-review explain", images: [])
    }
    func testClaudeCatalogComesFromInitializeWithoutSendingInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"trace":true}"#.write(to: root.appendingPathComponent(".claude-fixture-permissions.json"), atomically: true, encoding: .utf8)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scripts/fixtures/claude-stream.py")
        let commands = try await ClaudeHarness.commands(directory: root.path, executable: fixture)
        XCTAssertEqual(commands, [.init(name: "fixture-review", description: "Review fixture files", argumentHint: "[path]")])
        let trace = try String(contentsOf: root.appendingPathComponent(".claude-fixture-trace.jsonl"), encoding: .utf8)
        XCTAssertFalse(trace.contains("\"type\": \"user\""), "Discovery must not spend a model turn")
        XCTAssertTrue(trace.contains("manual"))
    }
    func testMalformedAndDuplicateCommandsAreNotInserted() throws {
        let commands = try ClaudeHarness.decodeCommands(["commands": [
            ["name": "plugin:review", "description": "Review"], ["name": "plugin:review"],
            ["name": ""], ["name": "bad\nname"], ["name": "/login"], ["name": "name with spaces"]]])
        XCTAssertEqual(commands.map(\.name), ["plugin:review"])
        XCTAssertThrowsError(try ClaudeHarness.decodeCommands([:]))
        XCTAssertEqual(try ClaudeHarness.decodeCommands(["commands": [[String: Any]]()]), [])
    }
    func testAuthStatusRequiresExplicitBooleanAndDoesNotKeepAccountMetadata() throws {
        let status = try ClaudeCLI.decodeAuthStatus(Data(#"{"loggedIn":false,"authMethod":"none","email":"private@example.test"}"#.utf8))
        XCTAssertEqual(status.title, "Signed out")
        let signedIn = try ClaudeCLI.decodeAuthStatus(Data(#"{"loggedIn":true,"authMethod":"claude.ai"}"#.utf8))
        XCTAssertEqual(signedIn.title, "Signed in · claude.ai")
        XCTAssertThrowsError(try ClaudeCLI.decodeAuthStatus(Data(#"{"error":"Keychain unavailable"}"#.utf8)))
        XCTAssertEqual(ClaudeCLI.loginArguments, ["auth", "login"])
    }
}
