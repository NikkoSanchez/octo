import XCTest
import OctoCore
@testable import OctoApp

@MainActor final class SidebarSearchTests: XCTestCase {
    private func search() -> (SidebarSearch, phrase: WorkspaceThread, other: WorkspaceThread) {
        var phrase = WorkspaceThread(title: "Phrase", workingDirectory: "/tmp")
        phrase.messages = [.init(role: .user, text: "This is a test.")]
        var other = WorkspaceThread(title: "Other", workingDirectory: "/tmp")
        other.messages = [.init(role: .user, text: "A test of something else")]
        let project = WorkspaceProject(name: "octo", rootPath: "/tmp/octo", threads: [phrase, other])
        let search = SidebarSearch()
        search.threads = { WorkspaceArchive(projects: [project]).searchableThreads }
        return (search, phrase, other)
    }

    private func settle(_ search: SidebarSearch, until query: String) async {
        for _ in 0..<200 where search.searchedQuery != query { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testTypingPublishesOnlyTheLatestQuerysResults() async {
        let (search, phrase, _) = search()
        // Each keystroke starts a search; earlier ones may finish after later ones.
        for prefix in ["T", "Th", "This", "This is", "This is a", "This is a test"] { search.query = prefix }
        XCTAssertTrue(search.results.isEmpty, "Searching happens off the keystroke")
        await settle(search, until: "This is a test")
        XCTAssertEqual(search.results.map(\.threadID), [phrase.id])
        XCTAssertTrue(search.hasQuery)
    }

    func testClearingTheQueryHidesResultsImmediately() async {
        let (search, _, other) = search()
        search.query = "something"
        await settle(search, until: "something")
        XCTAssertEqual(search.results.map(\.threadID), [other.id])
        search.query = "  "
        XCTAssertFalse(search.hasQuery)
        XCTAssertTrue(search.results.isEmpty)
        search.query = "missing words"
        await settle(search, until: "missing words")
        XCTAssertTrue(search.hasQuery, "An empty result still replaces the list with \"No results\"")
        XCTAssertTrue(search.results.isEmpty)
    }
}
