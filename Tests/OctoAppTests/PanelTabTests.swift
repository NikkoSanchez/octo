import AppKit
import SwiftUI
import WebKit
import XCTest
import OctoCore
@testable import OctoApp

@MainActor final class PanelTabTests: XCTestCase {
    private func repository(_ files: [String: String]) async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("octo-panel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = try XCTUnwrap(Executables.find("git"))
        _ = try await ProcessRunner.run(git, arguments: ["init", "--quiet"], directory: root)
        for (path, text) in files { try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        return root
    }
    private func waitForLoad(_ session: BrowserSession) async throws {
        for _ in 0..<250 where session.isLoading || session.currentURL == nil { try await Task.sleep(for: .milliseconds(20)) }
    }

    func testFileTabsSwitchEditorsAndKeepEachBuffer() async throws {
        let root = try await repository(["a.txt": "first\n", "b.txt": "second\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let review = ReviewModel(), id = UUID()
        var tabs = PanelTabs()
        await review.refresh(projectID: id, root: root.path)
        XCTAssertFalse(review.browsingFiles)
        tabs.openFile("a.txt", pinned: true)
        await review.show(tabs, projectID: id, root: root.path)
        let first = try XCTUnwrap(review.editor)
        XCTAssertEqual(first.context.path, "a.txt")
        first.suspend(); first.text = "edited\n"
        tabs.openFile("b.txt", pinned: true)
        await review.show(tabs, projectID: id, root: root.path)
        XCTAssertEqual(review.editor?.context.path, "b.txt")
        tabs.select(.file("a.txt"))
        await review.show(tabs, projectID: id, root: root.path)
        XCTAssertTrue(review.editor === first, "Returning to a tab reuses its editor session")
        XCTAssertEqual(review.editor?.text, "edited\n")
        tabs.select(.changes)
        await review.show(tabs, projectID: id, root: root.path)
        XCTAssertFalse(review.browsingFiles)
        tabs.close(.file("a.txt")); tabs.close(.file("b.txt")); tabs.showFiles()
        XCTAssertEqual(tabs.selected, .files)
        await review.show(tabs, projectID: id, root: root.path)
        XCTAssertTrue(review.browsingFiles)
        XCTAssertNil(review.snapshot, "The Files tab without an open file shows no preview")
        XCTAssertNil(review.selectedPath)
        tabs.close(.files); tabs.close(.changes)
        await review.show(tabs, projectID: id, root: root.path)
        XCTAssertTrue(review.browsingFiles, "The empty panel leaves review state alone")
        let browser = UUID()
        tabs.openFile("b.txt", pinned: true); await review.show(tabs, projectID: id, root: root.path)
        tabs.openBrowser(browser); await review.show(tabs, projectID: id, root: root.path)
        XCTAssertEqual(review.editor?.context.path, "b.txt", "Browser tabs leave the review state alone")
        first.resume()
    }

    func testRefreshInAnotherCheckoutRestoresTheSelectedFileTab() async throws {
        let one = try await repository(["shared.txt": "one\n"]), two = try await repository(["shared.txt": "two\n"])
        defer { try? FileManager.default.removeItem(at: one); try? FileManager.default.removeItem(at: two) }
        let review = ReviewModel(), id = UUID()
        var tabs = PanelTabs()
        tabs.openFile("shared.txt", pinned: true)
        review.adopt(tabs)
        await review.refresh(projectID: id, root: one.path)
        XCTAssertEqual(review.editor?.text, "one\n")
        review.adopt(tabs)
        await review.refresh(projectID: id, root: two.path)
        XCTAssertEqual(review.snapshot?.workingDirectory, two.path)
        XCTAssertEqual(review.editor?.text, "two\n")
    }

    func testStoreOpensClosesAndPersistsBrowserTabs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json"))
        let store = AppStore(storage: storage)
        defer { store.shutdown() }
        let project = WorkspaceProject(name: "Fixture", rootPath: directory.path, threads: [WorkspaceThread(workingDirectory: directory.path)])
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: project.threads[0].id)
        let first = store.openBrowserTab(projectID: project.id)
        let session = store.browserSession(first, projectID: project.id)
        XCTAssertTrue(store.browserSession(first, projectID: project.id) === session)
        session.onAddressChange?("http://localhost:3000/")
        let hidden = store.openBrowserTab(projectID: project.id, isPrivate: true)
        XCTAssertTrue(store.browserSession(hidden, projectID: project.id).isPrivate)
        XCTAssertFalse(store.browserSession(hidden, projectID: project.id).webView.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(session.webView.configuration.websiteDataStore.isPersistent)

        // A pop-up becomes a tab with the opener's profile.
        let popup = BrowserSession(isPrivate: true)
        store.browserSession(hidden, projectID: project.id).onOpenTab?(popup)
        let tabs = try XCTUnwrap(store.project?.panelTabs)
        XCTAssertEqual(tabs.browsers.count, 3)
        XCTAssertEqual(tabs.privateBrowsers.count, 2)
        let popupID = try XCTUnwrap(tabs.selectedBrowser)
        XCTAssertTrue(store.browserSession(popupID, projectID: project.id) === popup)
        popup.onClose?()
        XCTAssertEqual(store.project?.panelTabs.browsers, [first, hidden], "window.close() closes the pop-up's tab")
        XCTAssertNil(popup.onClose, "A closed session drops its callbacks")

        store.saveNow()
        let saved = try XCTUnwrap(storage.load().projects.first)
        XCTAssertEqual(saved.panelTabs.browsers, [first], "Private tabs are not saved")
        XCTAssertEqual(saved.panelTabs.browserAddresses[first], "http://localhost:3000/")

        store.closePanelTab(.browser(first), projectID: project.id)
        XCTAssertFalse(store.project?.panelTabs.browsers.contains(first) ?? true)
        XCTAssertFalse(store.browserSession(first, projectID: project.id) === session, "Closing a tab discards its page")
    }

    func testRestoredBrowserTabLoadsWhenShown() {
        var tabs = PanelTabs()
        let id = UUID()
        tabs.openBrowser(id); tabs.recordAddress("http://127.0.0.1:9/", for: id)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(storage: WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json")))
        defer { store.shutdown() }
        var project = WorkspaceProject(name: "Fixture", rootPath: directory.path)
        project.panelTabs = tabs
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: nil)
        let session = store.browserSession(id, projectID: project.id)
        XCTAssertTrue(session.isRestoring)
        XCTAssertEqual(session.address, "http://127.0.0.1:9/")
        XCTAssertNil(session.webView.url, "Restored tabs wait until they are shown")
        session.loadIfRestoring()
        XCTAssertFalse(session.isRestoring)
    }

    func testZoomStepsAndDeviceFit() {
        let session = BrowserSession()
        session.zoomIn(); XCTAssertEqual(session.zoom, 1.1)
        session.zoomOut(); session.zoomOut(); XCTAssertEqual(session.zoom, 0.9)
        XCTAssertEqual(session.webView.pageZoom, 0.9, accuracy: 0.0001)
        for _ in 0..<20 { session.zoomOut() }
        XCTAssertEqual(session.zoom, BrowserSession.zoomLevels.first)
        session.resetZoom(); XCTAssertEqual(session.webView.pageZoom, 1)
        session.device = .phone
        XCTAssertEqual(session.viewport, CGSize(width: 390, height: 844))
        session.landscape = true
        XCTAssertEqual(session.viewport, CGSize(width: 844, height: 390))
        XCTAssertEqual(BrowserSession.fitScale(viewport: CGSize(width: 390, height: 844), in: CGSize(width: 800, height: 422)), 0.5)
        XCTAssertEqual(BrowserSession.fitScale(viewport: CGSize(width: 390, height: 844), in: CGSize(width: 2000, height: 2000)), 1, "Small viewports are never enlarged")
        session.zoomIn(); session.setFitScale(0.5)
        XCTAssertEqual(session.webView.pageZoom, 0.55, accuracy: 0.0001, "Fit and user zoom combine")
    }

    func testDeviceViewportLaysOutAtEmulatedWidth() async throws {
        let session = BrowserSession()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 195, height: 422), styleMask: [.borderless], backing: .buffered, defer: false)
        session.webView.frame = window.contentView!.bounds
        window.contentView!.addSubview(session.webView)
        session.setFitScale(0.5)
        session.webView.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "http://localhost:3000"))
        try await waitForLoad(session)
        let width = try await session.webView.evaluateJavaScript("innerWidth") as? NSNumber
        XCTAssertEqual(width?.intValue, 390)
    }

    func testAppearanceDrivesPrefersColorScheme() async throws {
        let session = BrowserSession()
        session.webView.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "http://localhost:3000"))
        try await waitForLoad(session)
        for (appearance, dark) in [(BrowserAppearance.dark, true), (.light, false)] {
            session.appearance = appearance
            var matches: Bool?
            for _ in 0..<50 {
                matches = try await session.webView.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches") as? Bool
                if matches == dark { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(matches, dark, "\(appearance)")
        }
    }

    func testPopupOpensAsTabWithOpenerAndCanCloseItself() async throws {
        let session = BrowserSession()
        var child: BrowserSession?
        session.onOpenTab = { child = $0 }
        session.webView.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "http://localhost:3000"))
        try await waitForLoad(session)
        _ = try await session.webView.evaluateJavaScript("window.popup = window.open('about:blank'); window.popup !== null")
        let popup = try XCTUnwrap(child, "window.open must hand WebKit's pop-up configuration to a new tab")
        XCTAssertFalse(popup.isPrivate)
        XCTAssertTrue(popup.webView.configuration.websiteDataStore === session.webView.configuration.websiteDataStore)
        let hasOpener = try await popup.webView.evaluateJavaScript("window.opener !== null") as? Bool
        XCTAssertEqual(hasOpener, true)
        var closed = false
        popup.onClose = { closed = true }
        _ = try await session.webView.evaluateJavaScript("window.popup.close(); true")
        for _ in 0..<100 where !closed { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(closed)
    }

    func testHostedPanelMountsTabsAndLoadsBrowsersOnlyWhenShown() async throws {
        let root = try await repository(["a.txt": "first file\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: WorkspaceStore(fileURL: root.appendingPathComponent(".octo-workspace.json")))
        defer { store.shutdown() }
        let shown = UUID(), hidden = UUID()
        var tabs = PanelTabs()
        tabs.openBrowser(shown); tabs.recordAddress("http://127.0.0.1:9/shown", for: shown)
        tabs.openBrowser(hidden); tabs.recordAddress("http://127.0.0.1:9/hidden", for: hidden)
        tabs.openFile("a.txt", pinned: true)
        var project = WorkspaceProject(name: "Fixture", rootPath: root.path, threads: [WorkspaceThread(workingDirectory: root.path)])
        project.panelTabs = tabs
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: project.threads[0].id)
        store.showingReview = true
        let host = NSHostingView(rootView: WorkspaceView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        func textViews(_ view: NSView) -> [NSTextView] { ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(textViews) }
        for _ in 0..<100 where !textViews(host).contains(where: { $0.string == "first file\n" }) { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(textViews(host).contains { $0.string == "first file\n" }, "The selected file tab shows its editor")
        let first = store.browserSession(shown, projectID: project.id), second = store.browserSession(hidden, projectID: project.id)
        XCTAssertNotNil(first.webView.window, "Unselected browser tabs stay mounted")
        XCTAssertNotNil(second.webView.window)
        XCTAssertTrue(first.isRestoring && second.isRestoring, "Restored pages wait until shown")

        store.updatePanelTabs(project.id) { $0.select(.browser(shown)) }
        for _ in 0..<50 where first.isRestoring { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(first.isRestoring)
        XCTAssertTrue(second.isRestoring)

        store.closePanelTab(.browser(shown), projectID: project.id)
        for _ in 0..<50 where first.webView.window != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(first.webView.window, "A closed tab's page is unmounted")
        XCTAssertEqual(store.project?.panelTabs.selected, .browser(hidden))
        for _ in 0..<50 where second.isRestoring { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(second.isRestoring, "The neighbor that becomes selected loads")

        for tab in store.project?.panelTabs.tabs ?? [] { store.closePanelTab(tab, projectID: project.id) }
        for _ in 0..<50 where second.webView.window != nil || textViews(host).contains(where: { $0.string == "first file\n" && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(store.project?.panelTabs.selected, "Closing every tab leaves the surface picker")
        XCTAssertNil(second.webView.window)
    }

    func testSeparateWindowTakesThePageAndReturnsIt() throws {
        let session = BrowserSession()
        session.openInWindow()
        let window = try XCTUnwrap(session.webView.window)
        XCTAssertTrue(session.detached)
        session.openInWindow()
        XCTAssertTrue(session.webView.window === window, "Reopening focuses the same window")
        session.returnFromWindow()
        XCTAssertFalse(session.detached)
        XCTAssertNil(session.webView.superview, "The panel reattaches the page after the window closes")
        session.openInWindow()
        let next = try XCTUnwrap(session.webView.window)
        session.close()
        XCTAssertFalse(next.isVisible, "Closing the tab closes its window")
    }

    func testOpeningAnEmptyPanelGivesThePickerItsLetterKeys() async throws {
        let root = try await repository(["a.txt": "first\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: WorkspaceStore(fileURL: root.appendingPathComponent(".octo-workspace.json")))
        defer { store.shutdown() }
        var project = WorkspaceProject(name: "Fixture", rootPath: root.path, threads: [WorkspaceThread(workingDirectory: root.path)])
        project.panelTabs.close(.changes)
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id, selectedThreadID: project.threads[0].id)
        let host = NSHostingView(rootView: WorkspaceView(store: store))
        // A background test process cannot own the real key window, so the window reports itself key.
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        store.focusComposer()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(window.firstResponder is NSTextView, "The composer starts with focus")
        store.showingReview = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(window.firstResponder is NSTextView, "Opening an empty panel moves focus to its picker")
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                 context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        window.sendEvent(key)
        for _ in 0..<50 where store.project?.panelTabs.selected != .files { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.project?.panelTabs.selected, .files, "F opens Files")
        XCTAssertEqual(store.drafts[project.threads[0].id] ?? "", "", "The keystroke never reaches the composer")
    }

    func testWebInspectorOpens() async throws {
        let session = BrowserSession()
        try XCTSkipUnless(session.canOpenDevTools, "This WebKit does not expose an inspector; the menu item is disabled")
        XCTAssertEqual(session.webView.configuration.preferences.value(forKey: "developerExtrasEnabled") as? Bool, true,
                       "WebKit ignores the inspector's show request unless developer extras are enabled")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = session.webView
        defer { window.close() }
        session.webView.loadHTMLString("<p>Inspect me</p>", baseURL: URL(string: "http://localhost:3000"))
        try await waitForLoad(session)
        session.openDevTools()
        let inspector = try XCTUnwrap(session.webView.perform(NSSelectorFromString("_inspector"))?.takeUnretainedValue() as? NSObject)
        var visible = false
        for _ in 0..<150 where !visible {
            try await Task.sleep(for: .milliseconds(20))
            visible = inspector.value(forKey: "isVisible") as? Bool ?? false
        }
        XCTAssertTrue(visible, "Open Web Inspector shows WebKit's inspector")
        XCTAssertNil(session.error)
        inspector.perform(NSSelectorFromString("close"))
    }
}

private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}
