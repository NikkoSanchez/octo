import XCTest
import OctoCore
import OctoAgents
@testable import OctoApp

@MainActor private final class QueueHarness: AgentHarness {
    var onEvent: ((AgentEvent) -> Void)?
    var sent: [String] = []
    var sentSettings: [AgentSettings] = []
    var sentImages: [[ImageAttachment]] = []
    var steered: [String] = []
    var steering: CheckedContinuation<Void, Error>?
    func send(prompt: String, sessionID: String?, directory: String, settings: AgentSettings, images: [ImageAttachment]) async throws {
        sent.append(prompt); sentImages.append(images); sentSettings.append(settings); onEvent?(.session("fixture-session"))
    }
    func steer(prompt: String, images: [ImageAttachment]) async throws {
        steered.append(prompt)
        try await withCheckedThrowingContinuation { steering = $0 }
    }
    func interrupt() async { onEvent?(.interrupted) }
    func shutdown() { steering?.resume(throwing: CancellationError()); steering = nil }
}

@MainActor final class MessageQueueTests: XCTestCase {
    private func fixture() -> (AppStore, QueueHarness, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let harness = QueueHarness()
        let store = AppStore(storage: WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")),
                             harnessFactory: { _, _ in harness }, titleGenerator: { _, _, _ in nil })
        return (store, harness, root)
    }
    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    func testFIFOAttachmentsAndNavigationDoNotRerouteMessages() async throws {
        let (store, harness, root) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(store.thread?.id)
        store.drafts[id] = "First"; store.send(); await settle()
        let image = ImageAttachment(name: "fixture", pngData: Data("image".utf8))
        let context = ReviewSnapshot(projectID: store.project!.id, workingDirectory: store.thread!.workingDirectory,
                                     path: "file.swift", scope: .file, baseRevision: "fixture", lines: [])
        let source = SourceDocument(text: "let value = 42\n", context: context)
        let attachment = try XCTUnwrap(source.attachment(for: NSRange(location: 0, length: 14)))
        store.attachments[id] = [attachment]
        store.drafts[id] = "Second"; store.draftImages[id] = [image]; store.send()
        store.drafts[id] = "Third"; store.send()
        XCTAssertEqual(harness.sent, ["First"])
        XCTAssertEqual(store.queuedMessages[id]?.map(\.message.text), ["Second", "Third"])
        XCTAssertEqual(store.queuedMessages[id]?.first?.message.images, [image])
        XCTAssertEqual(store.drafts[id], "")
        store.newChat()
        XCTAssertNotEqual(store.thread?.id, id)
        harness.onEvent?(.finished); await settle()
        XCTAssertEqual(harness.sent, ["First", "Second\n\nSelected code context (captured snapshots):\n" + attachment.promptContext])
        XCTAssertEqual(harness.sentImages.last, [image])
        XCTAssertEqual(store.thread?.messages.count, 0)
        harness.onEvent?(.finished); await settle()
        XCTAssertEqual(harness.sent.last, "Third"); XCTAssertEqual(harness.sent.count, 3)
        harness.onEvent?(.finished); await settle()
        XCTAssertFalse(store.running.contains(id))
    }
    func testSteeringWhileQuestionWaitsPreservesWorkAndOnlyArchivesAfterAcceptance() async throws {
        let (store, harness, root) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(store.thread?.id)
        store.drafts[id] = "First"; store.send(); await settle()
        let question = AgentInteraction(title: "Choose direction", detail: "Fixture", fields: [], canDecline: true, cancellationDetail: "Cancel")
        harness.onEvent?(.interaction(question))
        store.drafts[id] = "Focus on this"; store.send()
        let queued = try XCTUnwrap(store.queuedMessages[id]?.first)
        store.steerQueued(queued.id, threadID: id); await settle()
        store.steerQueued(queued.id, threadID: id)
        store.removeQueued(queued.id, threadID: id)
        XCTAssertEqual(harness.steered, ["Focus on this"])
        XCTAssertEqual(store.thread?.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(store.interactions[id]?.count, 1)
        harness.steering?.resume(); harness.steering = nil; await settle()
        XCTAssertEqual(store.thread?.messages.last?.isSteering, true)
        XCTAssertEqual(store.interactions[id]?.count, 1, "Steering must not silently answer or cancel a question")
        XCTAssertEqual(ChatTurn.turns(store.thread!.messages).count, 1)
        harness.onEvent?(.message("Answer")); harness.onEvent?(.finished); await settle()
        XCTAssertEqual(store.thread?.messages.first?.work?.outcome, .completed)
        XCTAssertNil(store.thread?.messages.first(where: { $0.isSteering == true })?.work)
        XCTAssertEqual(ChatTurn.turns(store.thread!.messages).first?.responses.map(\.text), ["Focus on this", "Answer"])
        store.saveNow()
        let reloaded = try WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")).load()
        XCTAssertEqual(reloaded.chats?.threads.first?.messages.first(where: { $0.isSteering == true })?.text, "Focus on this")
    }
    func testCompletionBeforeSteerAcknowledgementDoesNotSendMessageTwice() async throws {
        let (store, harness, root) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(store.thread?.id)
        store.drafts[id] = "First"; store.send(); await settle()
        store.drafts[id] = "Steer"; store.send()
        store.steerQueued(store.queuedMessages[id]![0].id, threadID: id); await settle()
        store.drafts[id] = "Next"; store.send()
        harness.onEvent?(.message("Final")); harness.onEvent?(.finished); await settle()
        XCTAssertEqual(harness.sent, ["First"])
        harness.steering?.resume(); harness.steering = nil; await settle()
        XCTAssertEqual(harness.sent, ["First", "Next"])
        XCTAssertEqual(store.thread?.messages.map(\.text), ["First", "Steer", "Final", "Next"])
        XCTAssertEqual(store.thread?.messages[0].work?.outcome, .completed)
    }
    func testRejectedSteerAndStopPauseQueueWithoutDroppingInput() async throws {
        let (store, harness, root) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(store.thread?.id)
        store.drafts[id] = "First"; store.send(); await settle()
        store.drafts[id] = "Retain me"; store.send()
        let queued = store.queuedMessages[id]![0]
        store.steerQueued(queued.id, threadID: id); await settle()
        harness.steering?.resume(throwing: ProcessFailure.exited("Turn mismatch")); harness.steering = nil; await settle()
        XCTAssertNotNil(store.queueErrors[queued.id])
        XCTAssertEqual(store.queuedMessages[id]?.first?.message.text, "Retain me")
        store.stop(id); await settle()
        XCTAssertEqual(harness.sent, ["First"])
        XCTAssertEqual(store.thread?.messages.first?.work?.outcome, .stopped)
        store.selectPermissions(.readOnly, threadID: id)
        store.resumeQueue(id); await settle()
        XCTAssertEqual(harness.sent, ["First", "Retain me"])
        XCTAssertEqual(harness.sentSettings.last?.permissionMode, .readOnly, "Queued input must respect narrowed permissions")
        store.drafts[id] = "After failure"; store.send()
        harness.onEvent?(.failed("Disconnected")); await settle()
        XCTAssertEqual(store.queuedMessages[id]?.count, 1)
        XCTAssertTrue(store.pausedQueues.contains(id))
        store.removeQueued(store.queuedMessages[id]![0].id, threadID: id)
        XCTAssertEqual(store.queuedMessages[id]?.count, 0)
    }
    func testMissingToolCompletionAndLateStartCannotLeaveActivityRunning() async throws {
        let (store, harness, root) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(store.thread?.id)
        store.drafts[id] = "First"; store.send(); await settle()
        let tool = ToolActivity(id: "call", server: "cua_repl", tool: "js", state: .running)
        harness.onEvent?(.toolActivity(tool)); harness.onEvent?(.finished); await settle()
        XCTAssertEqual(store.thread?.messages.last?.toolActivity?.state, .interrupted)
        harness.onEvent?(.toolActivity(ToolActivity(id: "late", server: "cua_repl", tool: "js", state: .running)))
        XCTAssertEqual(store.thread?.messages.count, 2)
        XCTAssertFalse(store.canSteer(store.thread!))
    }
    func testStopDuringStartupAndProviderInterruptionNeverDrainQueue() async throws {
        let (store, harness, root) = fixture()
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let id = try XCTUnwrap(store.thread?.id)
        store.drafts[id] = "First"; store.send()
        store.drafts[id] = "Queued"; store.send(); store.stop(id); await settle()
        XCTAssertTrue(harness.sent.isEmpty)
        XCTAssertFalse(store.running.contains(id))
        XCTAssertEqual(store.queuedMessages[id]?.count, 1)
        store.resumeQueue(id); await settle()
        store.drafts[id] = "Still queued"; store.send()
        harness.onEvent?(.interrupted); await settle()
        XCTAssertEqual(harness.sent, ["Queued"])
        XCTAssertEqual(store.thread?.messages.last?.work?.outcome, .interrupted)
    }
}
