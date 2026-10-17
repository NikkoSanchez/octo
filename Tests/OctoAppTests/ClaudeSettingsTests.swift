import XCTest
import OctoCore
import OctoAgents
@testable import OctoApp

@MainActor final class ClaudeSettingsTests: XCTestCase {
    func testAutoDefaultManualChoiceAndPersistenceAcrossNewChats() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
        let store = AppStore(storage: storage)
        defer { store.shutdown() }
        store.changeHarness(.claude)
        let descriptor = try XCTUnwrap(store.harnessDescriptors.first { $0.id == .claude })
        XCTAssertEqual(descriptor.defaultPermissionMode, .autoReview)
        XCTAssertEqual(descriptor.permissionOptions.map(\.title), ["Manual", "Auto"])
        XCTAssertEqual(store.thread?.agentSettings.permissionMode ?? descriptor.defaultPermissionMode, .autoReview)
        let id = try XCTUnwrap(store.thread?.id)
        store.selectPermissions(.autoReview, threadID: id)
        store.running.insert(id); store.selectPermissions(.ask, threadID: id)
        XCTAssertEqual(store.thread?.agentSettings.permissionMode, .autoReview)
        store.running.remove(id); store.selectPermissions(.ask, threadID: id)
        store.saveNow()
        let reloaded = AppStore(storage: storage)
        defer { reloaded.shutdown() }
        XCTAssertEqual(reloaded.thread?.agentSettings.permissionMode, .ask, "Preserve an explicit Manual choice")
        reloaded.newThread(harness: .claude)
        XCTAssertEqual(reloaded.thread?.agentSettings.permissionMode, .ask)
        let newID = try XCTUnwrap(reloaded.thread?.id)
        reloaded.selectPermissions(.autoReview, threadID: newID)
        reloaded.newThread(harness: .claude)
        XCTAssertEqual(reloaded.thread?.agentSettings.permissionMode, .autoReview)
        reloaded.saveNow()
        XCTAssertEqual(try storage.load().rememberedAgentSettings?["claude"]?.permissionMode, .autoReview)
        XCTAssertEqual(store.harnessDescriptors.first { $0.id == .codex }?.defaultPermissionMode, .ask)
    }
    func testProviderCatalogIsolationEffortDefaultsAndPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json"))
        let store = AppStore(storage: storage)
        defer { store.shutdown() }
        let thread = WorkspaceThread(harness: .claude, workingDirectory: root.path)
        let project = WorkspaceProject(name: "Fixture", rootPath: root.path, threads: [thread])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id)
        let models = try JSONDecoder().decode([AgentModel].self, from: Data(#"[{"model":"sonnet","displayName":"Sonnet","description":"","hidden":false,"isDefault":false,"defaultReasoningEffort":"","supportedReasoningEfforts":[{"reasoningEffort":"high","description":""}]},{"model":"haiku","displayName":"Haiku","description":"","hidden":false,"isDefault":false,"defaultReasoningEffort":"","supportedReasoningEfforts":[]}]"#.utf8))
        store.modelCatalogs[store.modelKey(.claude, directory: root.path)] = models
        XCTAssertNotEqual(store.modelKey(.codex, directory: root.path), store.modelKey(thread))
        store.selectModel(models[0]); store.selectReasoning("high")
        XCTAssertEqual(store.thread?.agentSettings, .init(model: "sonnet", reasoningEffort: "high"))
        store.running.insert(thread.id); store.selectModel(models[1]); store.selectReasoning("low")
        XCTAssertEqual(store.thread?.agentSettings.model, "sonnet")
        store.running.remove(thread.id); store.selectModel(models[1])
        XCTAssertNil(store.thread?.agentSettings.reasoningEffort, "Use CLI defaults when not advertised")
        store.selectPermissions(.readOnly, threadID: thread.id)
        XCTAssertNil(store.thread?.agentSettings.permissionMode)
        store.selectPermissions(.ask, threadID: thread.id)
        store.saveNow()
        XCTAssertEqual(try storage.load().projects[0].threads[0].agentSettings, .init(model: "haiku", permissionMode: .ask))
        store.changeHarness(.codex)
        store.selectModel(models[0])
        XCTAssertNil(store.thread?.agentSettings.model, "A stale Claude menu cannot select a Codex model")
        store.changeHarness(.claude)
        XCTAssertEqual(store.thread?.agentSettings.model, "haiku")
        XCTAssertTrue(store.supportsImages(.claude))
        XCTAssertTrue(store.supportsModels(.claude))
        store.drafts[thread.id] = "Keep this draft"
        store.archive.projects[0].threads[0].agentSettings.model = "removed-model"
        store.send()
        XCTAssertEqual(store.drafts[thread.id], "Keep this draft")
        XCTAssertTrue(store.running.isEmpty)
        XCTAssertTrue(store.error?.contains("unavailable") == true)
    }
}
