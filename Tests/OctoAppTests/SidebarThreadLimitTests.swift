import XCTest
import OctoCore
@testable import OctoApp

final class SidebarThreadLimitTests: XCTestCase {
    private let threads = (0..<23).map { WorkspaceThread(title: "Thread \($0)", workingDirectory: "/tmp") }

    func testShortListsShowEverything() {
        let few = Array(threads.prefix(5))
        let result = SidebarThreadLimit.visible(few, limit: SidebarThreadLimit.initial) { _ in false }
        XCTAssertEqual(result.threads.map(\.id), few.map(\.id))
        XCTAssertEqual(result.hidden, 0)
    }

    func testPagesGrowByTenUntilExhausted() {
        var limit = SidebarThreadLimit.initial
        var result = SidebarThreadLimit.visible(threads, limit: limit) { _ in false }
        XCTAssertEqual(result.threads.map(\.id), threads.prefix(5).map(\.id))
        XCTAssertEqual(result.hidden, 18)
        limit += SidebarThreadLimit.page
        result = SidebarThreadLimit.visible(threads, limit: limit) { _ in false }
        XCTAssertEqual(result.threads.count, 15); XCTAssertEqual(result.hidden, 8)
        limit += SidebarThreadLimit.page
        result = SidebarThreadLimit.visible(threads, limit: limit) { _ in false }
        XCTAssertEqual(result.threads.map(\.id), threads.map(\.id)); XCTAssertEqual(result.hidden, 0)
    }

    func testSelectedAndRunningThreadsStayListedInOrder() {
        let selected = threads[12].id, running = threads[20].id
        let result = SidebarThreadLimit.visible(threads, limit: 5) { $0 == selected || $0 == running }
        XCTAssertEqual(result.threads.map(\.id), threads.prefix(5).map(\.id) + [selected, running])
        XCTAssertEqual(result.hidden, 16)
    }

    @MainActor func testCyclingSkipsThreadsBehindShowMore() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(storage: WorkspaceStore(fileURL: directory.appendingPathComponent("workspace.json")))
        defer { store.shutdown() }
        let project = WorkspaceProject(name: "Long", rootPath: directory.path, threads: threads)
        store.archive = WorkspaceArchive(projects: [project], selectedProjectID: project.id)
        let ordered = store.project!.orderedThreads
        store.selectThread(ordered[4], project: project)
        store.cycleThread(1)
        XCTAssertEqual(store.thread?.id, ordered[0].id, "Next wraps past the last listed thread")
        store.cycleThread(-1)
        XCTAssertEqual(store.thread?.id, ordered[4].id, "Previous wraps to the last listed thread")

        store.sidebarThreadLimits[project.id] = SidebarThreadLimit.initial + SidebarThreadLimit.page
        store.cycleThread(1)
        XCTAssertEqual(store.thread?.id, ordered[5].id, "Show more extends the cycle")

        // A hidden thread opened elsewhere (Recent) is listed while selected, so cycling continues from it.
        store.sidebarThreadLimits[project.id] = nil
        store.selectThread(ordered[20], project: project)
        store.cycleThread(1)
        XCTAssertEqual(store.thread?.id, ordered[0].id)
        store.selectThread(ordered[20], project: project)
        store.cycleThread(-1)
        XCTAssertEqual(store.thread?.id, ordered[4].id)
    }
}
