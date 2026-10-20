import XCTest
import OctoCore

final class ThreadSearchTests: XCTestCase {
    private func archive() -> (WorkspaceArchive, titled: WorkspaceThread, older: WorkspaceThread, newer: WorkspaceThread) {
        var titled = WorkspaceThread(title: "Fix runaway sidebar layout", workingDirectory: "/tmp")
        titled.lastActivityAt = Date(timeIntervalSince1970: 100)
        var older = WorkspaceThread(title: "Panel tabs", workingDirectory: "/tmp")
        older.lastActivityAt = Date(timeIntervalSince1970: 200)
        older.messages = [.init(role: .user, text: "Why does the sidebar hang?"),
                          .init(role: .activity, text: "sidebar tool output"),
                          .init(role: .assistant, text: String(repeating: "Context words here. ", count: 5) + "The SIDEBAR observation republished on every tick, so it re-rendered constantly.")]
        var newer = WorkspaceThread(title: "Ghostty paste", workingDirectory: "/tmp")
        newer.lastActivityAt = Date(timeIntervalSince1970: 300)
        newer.messages = [.init(role: .assistant, text: "Bracketed paste works in the sidebar terminal.")]
        let octo = WorkspaceProject(name: "octo", rootPath: "/tmp/octo", threads: [titled, older])
        let other = WorkspaceProject(name: "pfl-caller", rootPath: "/tmp/pfl", threads: [newer])
        return (WorkspaceArchive(projects: [octo, other]), titled, older, newer)
    }

    func testTitleMatchesRankFirstThenTheMostRecent() {
        let (archive, titled, older, newer) = archive()
        let results = ThreadSearch.results("sidebar", in: archive.searchableThreads)
        XCTAssertEqual(results.map(\.threadID), [titled.id, newer.id, older.id])
        XCTAssertNil(results[0].snippet, "A title match needs no message context")
        XCTAssertEqual(results[1].snippet, "Bracketed paste works in the sidebar terminal.")
    }

    func testEveryWordMustMatchAcrossTitleProjectAndMessages() {
        let (archive, _, older, newer) = archive()
        XCTAssertEqual(ThreadSearch.results("panel republished", in: archive.searchableThreads).map(\.threadID), [older.id])
        XCTAssertEqual(ThreadSearch.results("pfl paste", in: archive.searchableThreads).map(\.threadID), [newer.id], "Project names match")
        XCTAssertTrue(ThreadSearch.results("sidebar nonexistent", in: archive.searchableThreads).isEmpty)
        XCTAssertTrue(ThreadSearch.results("   ", in: archive.searchableThreads).isEmpty)
        XCTAssertTrue(ThreadSearch.results("tool output", in: archive.searchableThreads).isEmpty, "Tool activity is not searched")
    }

    func testSnippetShowsTheNewestMatchInContext() {
        let (archive, _, older, _) = archive()
        let result = ThreadSearch.results("Panel observation", in: archive.searchableThreads).first
        XCTAssertEqual(result?.threadID, older.id)
        let snippet = try? XCTUnwrap(result?.snippet)
        XCTAssertEqual(snippet?.hasPrefix("…"), true, "Text before the match is cut")
        XCTAssertEqual(snippet?.contains("SIDEBAR observation republished"), true)
        XCTAssertFalse(snippet?.contains("\n") ?? true)
    }
}
