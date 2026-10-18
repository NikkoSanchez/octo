import XCTest
@testable import OctoCore

final class WorkspaceArchiveWriterTests: XCTestCase {
    private func storage() throws -> (WorkspaceStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (WorkspaceStore(fileURL: root.appendingPathComponent("workspace.json")), root)
    }
    private func archive(_ name: String) -> WorkspaceArchive {
        WorkspaceArchive(projects: [WorkspaceProject(name: name, rootPath: "/tmp/\(name)")])
    }

    func testBackgroundWritesCoalesceToNewestSnapshot() throws {
        let (store, root) = try storage()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = WorkspaceArchiveWriter(storage: store)
        for index in 0..<50 { writer.write(archive("p\(index)")) { XCTFail("\($0)") } }
        // A synchronous write queues behind pending work, so the file is settled afterwards.
        try writer.writeNow(archive("final"))
        XCTAssertEqual(try store.load().projects.map(\.name), ["final"])
    }

    func testWriteNowSupersedesSnapshotNotYetStarted() throws {
        let (store, root) = try storage()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = WorkspaceArchiveWriter(storage: store)
        writer.write(archive("stale")) { XCTFail("\($0)") }
        try writer.writeNow(archive("current"))
        let settled = expectation(description: "queue drained")
        writer.write(archive("current")) { XCTFail("\($0)") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(try store.load().projects.map(\.name), ["current"])
    }

    func testBackgroundWriteFailureIsReported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A directory at the archive path makes the final rename fail.
        let path = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let writer = WorkspaceArchiveWriter(storage: WorkspaceStore(fileURL: path))
        let failed = expectation(description: "failure reported")
        writer.write(archive("x")) { _ in failed.fulfill() }
        wait(for: [failed], timeout: 5)
    }
}
