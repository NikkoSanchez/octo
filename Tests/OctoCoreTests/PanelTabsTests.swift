import XCTest
@testable import OctoCore

final class PanelTabsTests: XCTestCase {
    func testPreviewTabIsReplacedUntilPinned() {
        var tabs = PanelTabs()
        tabs.openFile("a.swift", pinned: false)
        tabs.openFile("b.swift", pinned: false)
        XCTAssertEqual(tabs.tabs, [.changes, .file("b.swift")], "A single click replaces the preview tab")
        XCTAssertEqual(tabs.preview, "b.swift")
        tabs.pin("b.swift")
        tabs.openFile("c.swift", pinned: false)
        XCTAssertEqual(tabs.tabs, [.changes, .file("b.swift"), .file("c.swift")])
        tabs.openFile("c.swift", pinned: true)
        XCTAssertNil(tabs.preview, "Opening the preview file explicitly keeps it")
        tabs.openFile("d.swift", pinned: true)
        tabs.openFile("b.swift", pinned: false)
        XCTAssertEqual(tabs.files, ["b.swift", "c.swift", "d.swift"], "Reopening an open file selects it without duplicating")
        XCTAssertEqual(tabs.selected, .file("b.swift"))
        XCTAssertNil(tabs.preview)
    }

    func testClosingSelectsNeighborUntilNothingIsOpen() {
        var tabs = PanelTabs()
        let browser = UUID()
        tabs.openFile("a", pinned: true); tabs.openBrowser(browser); tabs.openFile("b", pinned: true)
        tabs.select(.browser(browser))
        XCTAssertTrue(tabs.close(.browser(browser)))
        XCTAssertEqual(tabs.selected, .file("b"), "The right neighbor is selected")
        XCTAssertTrue(tabs.close(.file("b")))
        XCTAssertEqual(tabs.selected, .file("a"), "The left neighbor is selected when there is no right one")
        tabs.select(.changes)
        XCTAssertTrue(tabs.close(.file("a")))
        XCTAssertEqual(tabs.selected, .changes, "Closing an unselected tab keeps the selection")
        XCTAssertFalse(tabs.close(.file("missing")))
        XCTAssertTrue(tabs.close(.changes), "Changes closes like any other tab")
        XCTAssertTrue(tabs.tabs.isEmpty)
        XCTAssertNil(tabs.selected)
        XCTAssertFalse(tabs.showsReview, "An empty panel offers surfaces instead of review content")
        tabs.selectAdjacent(1)
        XCTAssertNil(tabs.selected)
        tabs.showChanges()
        XCTAssertEqual(tabs.tabs, [.changes])
        XCTAssertEqual(tabs.selected, .changes)
    }

    func testFilesTabIsReplacedByTheFirstOpenedFile() {
        var tabs = PanelTabs()
        tabs.close(.changes)
        tabs.showsFileTree = false
        tabs.showFiles()
        XCTAssertEqual(tabs.tabs, [.files])
        XCTAssertEqual(tabs.selected, .files)
        XCTAssertTrue(tabs.isBrowsingFiles)
        XCTAssertTrue(tabs.showsFileTree, "Showing Files reveals the tree")
        tabs.showFiles()
        XCTAssertEqual(tabs.tabs, [.files], "Files opens once")
        tabs.openFile("a", pinned: false)
        XCTAssertEqual(tabs.tabs, [.file("a")], "The first file takes the Files tab's place")
        XCTAssertEqual(tabs.preview, "a")
        tabs.openFile("b", pinned: true); tabs.select(.file("a"))
        let browser = UUID()
        tabs.openBrowser(browser)
        XCTAssertFalse(tabs.isBrowsingFiles)
        tabs.showFiles()
        XCTAssertEqual(tabs.selected, .file("a"), "The most recently viewed file returns")
        XCTAssertEqual(tabs.recentBrowser, browser)
        tabs.close(.file("a")); tabs.select(.browser(browser)); tabs.showFiles()
        XCTAssertEqual(tabs.selected, .file("b"))
    }

    func testAdjacentSelectionWraps() {
        var tabs = PanelTabs()
        let browser = UUID()
        tabs.openFile("a", pinned: true); tabs.openBrowser(browser)
        tabs.selectAdjacent(1)
        XCTAssertEqual(tabs.selected, .changes)
        tabs.selectAdjacent(-1)
        XCTAssertEqual(tabs.selected, .browser(browser))
    }

    func testPersistenceKeepsAddressesAndDropsPrivateTabs() throws {
        var tabs = PanelTabs()
        let browser = UUID(), privateBrowser = UUID()
        tabs.openFile("Sources/a.swift", pinned: false)
        tabs.openBrowser(browser)
        tabs.recordAddress("http://localhost:3000/", for: browser)
        tabs.openBrowser(privateBrowser, isPrivate: true)
        tabs.recordAddress("https://private.example/", for: privateBrowser)
        XCTAssertNil(tabs.browserAddresses[privateBrowser], "Private addresses are never recorded")
        let decoded = try JSONDecoder().decode(PanelTabs.self, from: JSONEncoder().encode(tabs))
        XCTAssertEqual(decoded.tabs, [.changes, .file("Sources/a.swift"), .browser(browser)])
        XCTAssertEqual(decoded.selected, .changes, "A selected private tab falls back to the first saved tab")
        XCTAssertEqual(decoded.preview, "Sources/a.swift")
        XCTAssertEqual(decoded.browserAddresses, [browser: "http://localhost:3000/"])
        XCTAssertTrue(decoded.privateBrowsers.isEmpty)
    }

    func testDecodingRepairsMalformedTabs() throws {
        let browser = UUID()
        let json = """
        {"tabs":[{"file":{"_0":"a"}},{"future":{}},{"file":{"_0":"a"}},{"browser":{"_0":"\(browser.uuidString)"}}],
         "selected":{"file":{"_0":"gone"}},"preview":"gone","showsFileTree":false}
        """
        let tabs = try JSONDecoder().decode(PanelTabs.self, from: Data(json.utf8))
        XCTAssertEqual(tabs.tabs, [.file("a"), .browser(browser)])
        XCTAssertEqual(tabs.selected, .file("a"), "A missing selection falls back to the first tab")
        XCTAssertNil(tabs.preview)
        XCTAssertFalse(tabs.showsFileTree)
        var empty = PanelTabs()
        empty.close(.changes)
        let decoded = try JSONDecoder().decode(PanelTabs.self, from: JSONEncoder().encode(empty))
        XCTAssertTrue(decoded.tabs.isEmpty, "Closing every tab survives relaunch")
        XCTAssertNil(decoded.selected)
    }

    func testProjectsWithoutPanelTabsDecode() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"Legacy","rootPath":"/tmp/legacy","threads":[]}"#
        let project = try JSONDecoder().decode(WorkspaceProject.self, from: Data(json.utf8))
        XCTAssertEqual(project.panelTabs, PanelTabs())
    }
}
