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
        let store = AppStore(storage: storage, executables: fixtureExecutables)
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
    func testNestedAgentMenuKeepsThreadForModelsAndBranchesOnlyForProviderWithHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")))
        defer { store.shutdown() }
        var thread = WorkspaceThread(harness: .claude, workingDirectory: root.path)
        thread.messages = [ChatMessage(role: .user, text: "Started on Claude")]
        let project = WorkspaceProject(name: "Fixture", rootPath: root.path, threads: [thread])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id)
        func catalog(_ names: [String]) throws -> [AgentModel] {
            try JSONDecoder().decode([AgentModel].self, from: Data(("[" + names.map { #"{"model":"\#($0)","displayName":"\#($0)","description":"","hidden":false,"isDefault":false,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"medium","description":""}]}"# }.joined(separator: ",") + "]").utf8))
        }
        let claude = try catalog(["sonnet", "opus"]), codex = try catalog(["gpt-5.5"])
        store.modelCatalogs[store.modelKey(.claude, directory: root.path)] = claude
        store.modelCatalogs[store.modelKey(.codex, directory: root.path)] = codex
        store.selectAgent(.claude, model: claude[1], directory: root.path)
        XCTAssertEqual(store.thread?.id, thread.id, "Changing model never starts a thread")
        XCTAssertEqual(store.thread?.agentSettings.model, "opus")
        store.selectAgent(.codex, model: codex[0], directory: root.path)
        XCTAssertNotEqual(store.thread?.id, thread.id, "A Claude session cannot continue in Codex")
        XCTAssertEqual(store.thread?.harness, .codex)
        XCTAssertEqual(store.thread?.agentSettings.model, "gpt-5.5")
        XCTAssertEqual(store.archive.projects[0].threads.first { $0.id == thread.id }?.harness, .claude)
        let draft = try XCTUnwrap(store.thread?.id)
        store.selectAgent(.claude, model: claude[0], directory: root.path)
        XCTAssertEqual(store.thread?.id, draft, "An empty draft switches provider in place")
        XCTAssertEqual(store.thread?.harness, .claude)
        XCTAssertEqual(store.thread?.agentSettings.model, "sonnet")
        store.selectAgent(.claude, model: codex[0], directory: root.path)
        XCTAssertEqual(store.thread?.agentSettings.model, "sonnet", "Another provider's model is rejected")
    }
}
