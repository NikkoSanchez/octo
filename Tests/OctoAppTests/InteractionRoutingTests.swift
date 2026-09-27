import XCTest
import OctoCore
@testable import OctoAgents
@testable import OctoApp

@MainActor final class InteractionRoutingTests: XCTestCase {
    func testConcurrentOwnershipLifecycleAndPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
        let store = AppStore(storage: storage); defer { store.shutdown() }
        var first = WorkspaceThread(workingDirectory: root.path), second = WorkspaceThread(workingDirectory: root.path)
        first.messages = [.init(role: .user, text: "One")]; second.messages = [.init(role: .user, text: "Two")]
        let project = WorkspaceProject(name: "Fixtures", rootPath: root.path, threads: [first, second])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: second.id)
        store.beginWork(first.id); store.beginWork(second.id)
        let request = AgentInteraction(id: UUID(), title: "Request", detail: "Fixture", target: "Safari", fields: [], canDecline: true, cancellationDetail: "Cancel")
        store.handle(.interaction(request), threadID: first.id)
        store.handle(.interaction(request), threadID: first.id)
        XCTAssertEqual(store.interactions[first.id]?.count, 1)
        XCTAssertNil(store.interactions[second.id])
        XCTAssertNotNil(store.respond(to: request, threadID: second.id, response: .cancel))
        var tool = ToolActivity(id: "connection:turn:call", server: "fixture", tool: "test", state: .running)
        store.handle(.toolActivity(tool), threadID: first.id)
        store.handle(.toolActivity(tool), threadID: first.id)
        store.handle(.activityDelta("Independent commentary"), threadID: first.id)
        tool.state = .completed; tool.detail = "Done"
        store.handle(.toolActivity(tool), threadID: first.id)
        store.handle(.toolActivity(tool), threadID: first.id)
        XCTAssertEqual(store.archive.projects[0].threads[0].messages.count, 3)
        XCTAssertEqual(store.archive.projects[0].threads[0].messages[1].text, tool.text)
        XCTAssertEqual(store.thread?.messages.count, 1)
        store.handle(.interactionResolved(request.id), threadID: first.id)
        XCTAssertEqual(store.interactions[first.id]?.count, 0)
        store.handle(.interaction(request), threadID: second.id)
        store.handle(.failed("Transport disconnected"), threadID: second.id)
        XCTAssertEqual(store.interactions[second.id]?.count, 0)
        store.handle(.interactionUnavailable("Unsupported form"), threadID: first.id)
        XCTAssertEqual(store.archive.projects[0].threads[0].messages.last?.role, .error)
        store.handle(.finished, threadID: first.id)
        store.saveNow()
        let reloaded = try storage.load()
        XCTAssertEqual(reloaded.projects[0].threads[0].messages[1].toolActivity, tool)
        XCTAssertEqual(reloaded.projects[0].threads[0].messages[1].text, tool.text)
        var interruptedArchive = reloaded
        interruptedArchive.projects[0].threads[0].messages[1].toolActivity?.state = .running
        try storage.save(interruptedArchive)
        let restarted = AppStore(storage: storage)
        XCTAssertEqual(restarted.archive.projects[0].threads[0].messages[1].toolActivity?.state, .interrupted)
        restarted.shutdown()
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first.messages[0])) as! [String: Any]
        legacy.removeValue(forKey: "toolActivity")
        XCTAssertNil(try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: legacy)).toolActivity)
    }
    func testUnsupportedHarnessDoesNotOfferInteractions() throws {
        let descriptor = try XCTUnwrap(HarnessRegistry.descriptors.first { $0.id == .claude })
        XCTAssertFalse(descriptor.capabilities.forms)
        XCTAssertFalse(descriptor.capabilities.appAccess)
        XCTAssertFalse(descriptor.capabilities.toolInventory)
        XCTAssertThrowsError(try ClaudeHarness().respond(to: UUID(), with: .cancel))
    }
}
