import XCTest
import AppKit
import Combine
import OctoCore
import OctoAgents
@testable import OctoApp

@MainActor final class WorkspaceTests: XCTestCase {
    func testCodeGutterAttachmentOnlyUpdatesDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(storage: WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json")))
        let thread = WorkspaceThread(workingDirectory: directory.path)
        let project = WorkspaceProject(name: "Test", rootPath: directory.path, threads: [thread])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id)
        let snapshot = ReviewSnapshot(projectID: project.id, workingDirectory: directory.path, path: "sample.swift", scope: .working, baseRevision: "base", lines: [
            .init(id: 0, kind: .addition, text: "let value = 42", newLine: 7)
        ])
        let document = ReviewDocument(snapshot: snapshot)
        let range = try XCTUnwrap(document.attachmentRange(forLineAtUTF16Offset: 0, selection: NSRange(location: 0, length: 0)))
        let attachment = try XCTUnwrap(document.attachment(for: range))
        store.attach(attachment)
        XCTAssertEqual(store.attachments[thread.id], [attachment])
        XCTAssertEqual(store.attachments[thread.id]?.first?.newLines, 7...7)
        XCTAssertTrue(store.thread?.messages.isEmpty == true)
        XCTAssertTrue(store.running.isEmpty)
        XCTAssertFalse(store.canSend(thread), "Attaching code must not send or invent a message")
        store.shutdown()
    }

    func testScreenshotPasteIsDraftOnlyAndRejectsUnsupportedProvider() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(storage: WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json")))
        let thread = WorkspaceThread(workingDirectory: directory.path)
        let project = WorkspaceProject(name: "Test", rootPath: directory.path, threads: [thread])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("ordinary text", forType: .string)
        XCTAssertFalse(store.pasteScreenshot(from: board, threadID: thread.id))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        board.clearContents(); board.setData(png, forType: .png)
        XCTAssertTrue(store.pasteScreenshot(from: board, threadID: thread.id))
        XCTAssertEqual(store.draftImages[thread.id]?.count, 1)
        XCTAssertTrue(store.canSend(thread), "Image-only messages are sendable")
        XCTAssertTrue(store.thread?.messages.isEmpty == true)
        XCTAssertTrue(store.running.isEmpty)
        let captured = try XCTUnwrap(store.draftImages[thread.id]?.first?.pngData)
        board.clearContents(); board.setData(Data("invalid".utf8), forType: .png)
        XCTAssertTrue(store.pasteScreenshot(from: board, threadID: thread.id))
        XCTAssertEqual(store.draftImages[thread.id]?.first?.pngData, captured)
        XCTAssertEqual(store.draftImages[thread.id]?.count, 1)
        store.changeHarness(.claude)
        board.clearContents(); board.setData(png, forType: .png)
        XCTAssertTrue(store.pasteScreenshot(from: board, threadID: thread.id))
        store.send()
        XCTAssertEqual(store.draftImages[thread.id]?.count, 1)
        XCTAssertTrue(store.thread?.messages.isEmpty == true)
        store.changeHarness(.codex)
        for _ in 0..<5 { store.pasteScreenshot(from: board, threadID: thread.id) }
        XCTAssertEqual(store.draftImages[thread.id]?.count, 4)
        store.newThread()
        XCTAssertTrue(store.draftImages[store.thread!.id] == nil)
        store.deleteThread(thread.id, projectID: project.id)
        XCTAssertNil(store.draftImages[thread.id])
        store.shutdown()
    }

    func testExecutablePreferencePersistsInvalidatesCatalogAndProtectsActiveTurn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "octo-tests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("codex fixture")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let storage = WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let store = AppStore(storage: storage, preferences: preferences)
        let thread = WorkspaceThread(workingDirectory: directory.path)
        let project = WorkspaceProject(name: "Test", rootPath: directory.path, threads: [thread])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id)
        store.modelCatalogs[directory.path] = []; store.modelErrors[directory.path] = "old error"
        let initial = store.codexConfigurationID
        store.setCodexExecutable(path: executable.path)
        XCTAssertNotEqual(initial, store.codexConfigurationID)
        XCTAssertEqual(store.codexExecutable, executable)
        XCTAssertEqual(store.harnessDescriptors.first?.executable, executable)
        XCTAssertTrue(store.modelCatalogs.isEmpty); XCTAssertTrue(store.modelErrors.isEmpty)
        XCTAssertEqual(AppStore(storage: storage, preferences: preferences).codexExecutablePath, executable.path)
        store.running.insert(thread.id)
        store.setCodexExecutable(path: nil)
        XCTAssertEqual(store.codexExecutablePath, executable.path)
        store.running.remove(thread.id)
        store.setCodexExecutable(path: directory.path)
        XCTAssertEqual(store.codexExecutablePath, executable.path)
        try FileManager.default.removeItem(at: executable)
        XCTAssertNil(store.codexExecutable, "A missing custom executable must not silently fall back")
        store.drafts[thread.id] = "Keep draft"
        store.send()
        XCTAssertEqual(store.drafts[thread.id], "Keep draft")
        XCTAssertTrue(store.running.isEmpty)
        store.setCodexExecutable(path: nil)
        XCTAssertNil(store.codexExecutablePath)
        XCTAssertNil(AppStore(storage: storage, preferences: preferences).codexExecutablePath)
        store.shutdown()
    }

    func testModelSelectionPersistsNormalizesAndRespectsRunningTurn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let store = AppStore(storage: storage)
        let thread = WorkspaceThread(workingDirectory: directory.path)
        let project = WorkspaceProject(name: "Test", rootPath: directory.path, threads: [thread])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id)
        let data = Data(#"[{"model":"a","displayName":"A","description":"","hidden":false,"isDefault":true,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"medium","description":""},{"reasoningEffort":"high","description":""}]},{"model":"b","displayName":"B","description":"","hidden":false,"isDefault":false,"defaultReasoningEffort":"low","supportedReasoningEfforts":[{"reasoningEffort":"low","description":""}]}]"#.utf8)
        let models = try JSONDecoder().decode([AgentModel].self, from: data)
        store.modelCatalogs[directory.path] = models
        store.selectModel(models[0]); store.selectReasoning("high")
        XCTAssertEqual(store.thread?.agentSettings, AgentSettings(model: "a", reasoningEffort: "high"))
        store.selectReasoning("unsupported")
        XCTAssertEqual(store.thread?.agentSettings.reasoningEffort, "high")
        store.running.insert(thread.id); store.selectModel(models[1]); store.changeHarness(.claude)
        XCTAssertEqual(store.thread?.harness, .codex)
        XCTAssertEqual(store.thread?.agentSettings.model, "a")
        store.running.remove(thread.id); store.selectModel(models[1])
        XCTAssertEqual(store.thread?.agentSettings, AgentSettings(model: "b", reasoningEffort: "low"))
        store.saveNow()
        XCTAssertEqual(try storage.load().projects[0].threads[0].agentSettings, store.thread?.agentSettings)
        store.modelCatalogs[directory.path] = []
        store.drafts[thread.id] = "Keep this draft"
        store.send()
        XCTAssertEqual(store.drafts[thread.id], "Keep this draft")
        XCTAssertTrue(store.running.isEmpty)
        store.changeHarness(.claude)
        XCTAssertEqual(store.thread?.agentSettings, AgentSettings())
        store.shutdown()
    }

    func testRemovalProtectsRunningWorkAndCleansDrafts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(storage: WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json")))
        let thread = WorkspaceThread(workingDirectory: directory.path)
        let project = WorkspaceProject(name: "Test", rootPath: directory.path, threads: [thread])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id)
        store.drafts[thread.id] = "Keep this draft"
        store.running.insert(thread.id)
        store.deleteThread(thread.id, projectID: project.id)
        store.removeProject(project.id)
        XCTAssertEqual(store.project?.threads.count, 1)
        XCTAssertEqual(store.drafts[thread.id], "Keep this draft")
        store.running.remove(thread.id)
        store.deleteThread(thread.id, projectID: project.id)
        XCTAssertNil(store.drafts[thread.id])
        XCTAssertNil(store.thread)
        store.removeProject(project.id)
        XCTAssertTrue(store.archive.projects.isEmpty)
        store.shutdown()
    }

    func testBrowserSwitchKeepsPreviewAndRestoresEachSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = try XCTUnwrap(Executables.find("git"))
        let result = try await ProcessRunner.run(git, arguments: ["init", "--quiet"], directory: directory)
        XCTAssertEqual(result.status, 0)
        try "first\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "second\n".write(to: directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let model = ReviewModel(), projectID = UUID()
        await model.refresh(projectID: projectID, root: directory.path)
        XCTAssertEqual(model.snapshot?.path, "a.txt")
        var blankPreviews = 0
        let subscription = model.$snapshot.dropFirst().sink { if $0 == nil { blankPreviews += 1 } }
        defer { subscription.cancel() }
        model.browsingFiles = true
        await model.switchBrowser(projectID: projectID, root: directory.path)
        await model.selectPath("b.txt", projectID: projectID, root: directory.path)
        XCTAssertEqual(model.snapshot?.scope, .file)
        model.browsingFiles = false
        await model.switchBrowser(projectID: projectID, root: directory.path)
        XCTAssertEqual(model.snapshot?.path, "a.txt")
        model.browsingFiles = true
        await model.switchBrowser(projectID: projectID, root: directory.path)
        XCTAssertEqual(model.snapshot?.path, "b.txt")
        XCTAssertEqual(blankPreviews, 0)
        XCTAssertFalse(model.loadingSnapshot)
    }
}
