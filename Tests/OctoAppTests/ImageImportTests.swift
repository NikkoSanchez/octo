import XCTest
import AppKit
import OctoCore
@testable import OctoApp

@MainActor final class ImageImportTests: XCTestCase {
    func testFileImportKeepsSnapshotAndOwningDraftWithoutSending() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppStore(storage: WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json")))
        defer { store.shutdown() }
        let first = WorkspaceThread(workingDirectory: directory.path)
        let second = WorkspaceThread(workingDirectory: directory.path)
        let project = WorkspaceProject(name: "Test", rootPath: directory.path, threads: [first, second])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: second.id)
        let file = directory.appendingPathComponent("chosen photo.jpg")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: file)
        await store.importImages([file], threadID: first.id)
        try Data("changed file".utf8).write(to: file)
        let image = try XCTUnwrap(store.draftImages[first.id]?.first)
        XCTAssertEqual(image.name, "chosen photo.jpg")
        XCTAssertEqual(Array(image.pngData.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual(NSBitmapImageRep(data: image.pngData)?.pixelsWide, 3)
        XCTAssertNil(store.draftImages[second.id])
        XCTAssertTrue(store.archive.projects[0].threads.allSatisfy { $0.messages.isEmpty })
        XCTAssertTrue(store.running.isEmpty)
        XCTAssertTrue(store.importingImages.isEmpty)
        XCTAssertTrue(store.canSend(first))
    }

    func testFileImportLimitsInvalidInputAndUnsupportedProvider() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppStore(storage: WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json")))
        defer { store.shutdown() }
        let thread = WorkspaceThread(workingDirectory: directory.path)
        let project = WorkspaceProject(name: "Test", rootPath: directory.path, threads: [thread])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: thread.id)
        let file = directory.appendingPathComponent("sample.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        await store.importImages(Array(repeating: file, count: 5), threadID: thread.id)
        XCTAssertNil(store.draftImages[thread.id], "An oversized selection is rejected before partial import")
        await store.importImages(Array(repeating: file, count: 4), threadID: thread.id)
        XCTAssertEqual(store.draftImages[thread.id]?.count, 4)
        await store.importImages([file], threadID: thread.id)
        XCTAssertEqual(store.draftImages[thread.id]?.count, 4)
        store.draftImages[thread.id] = []
        store.changeHarness(.claude)
        await store.importImages([file], threadID: thread.id)
        XCTAssertTrue(store.draftImages[thread.id]?.isEmpty == true)
        XCTAssertTrue(store.error?.contains("Codex") == true)
        store.changeHarness(.codex)
        let invalid = directory.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalid)
        await store.importImages([invalid, file], threadID: thread.id)
        XCTAssertEqual(store.draftImages[thread.id]?.count, 1, "A bad file does not discard valid selections")
        XCTAssertTrue(store.error?.contains("invalid.png") == true)
        XCTAssertThrowsError(try DraftImageImport.read(directory))
        XCTAssertThrowsError(try DraftImageImport.decode(Data(repeating: 0, count: DraftImageImport.sourceLimit + 1), name: "large.png"))
        await store.importImages([file], threadID: UUID())
        XCTAssertEqual(store.draftImages.count, 1, "Deleted or unknown chats cannot acquire attachments")
    }

    func testNativeDividerOwnsHitTestingAndDisablesWhileHidden() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = CursorProbe(frame: NSRect(x: 10, y: 0, width: 7, height: 100))
        window.contentView?.addSubview(view)
        view.enabled = true
        view.resetCursorRects()
        XCTAssertEqual(view.rects.last, view.visibleRect)
        XCTAssertTrue(view.cursors.last === NSCursor.resizeLeftRight)
        XCTAssertTrue(view.hitTest(NSPoint(x: 12, y: 50)) === view)
        view.rects = []; view.cursors = []
        view.enabled = false
        view.resetCursorRects()
        XCTAssertTrue(view.rects.isEmpty, "Mounted hidden dividers must not register resize cursors")
        XCTAssertNil(view.hitTest(NSPoint(x: 12, y: 50)))
        view.removeFromSuperview()
    }
    func testNativeDividerSetsCursorAndRetainsDragOriginWhileItsFrameMoves() throws {
        let view = ResizeCursorView(frame: NSRect(x: 0, y: 0, width: 7, height: 100))
        view.enabled = true
        var translations: [CGFloat] = [], completions = 0
        view.onDrag = { translations.append($0) }
        view.onEnd = { completions += 1 }
        func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 50), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSCursor.arrow.set()
        defer { NSCursor.arrow.set() }
        view.cursorUpdate(with: try event(.mouseMoved, 3))
        XCTAssertEqual(NSCursor.current, .resizeLeftRight)
        view.mouseDown(with: try event(.leftMouseDown, 3))
        view.setFrameOrigin(NSPoint(x: 50, y: 0))
        view.mouseDragged(with: try event(.leftMouseDragged, 53))
        view.mouseUp(with: try event(.leftMouseUp, 53))
        XCTAssertEqual(translations, [0, 50])
        XCTAssertEqual(completions, 1)
        view.enabled = false
        NSCursor.arrow.set()
        view.cursorUpdate(with: try event(.mouseMoved, 53))
        XCTAssertEqual(NSCursor.current, .arrow)
    }

}

private final class CursorProbe: ResizeCursorView {
    var rects: [NSRect] = []
    var cursors: [NSCursor] = []
    override func addCursorRect(_ rect: NSRect, cursor: NSCursor) {
        rects.append(rect); cursors.append(cursor)
        super.addCursorRect(rect, cursor: cursor)
    }
}
