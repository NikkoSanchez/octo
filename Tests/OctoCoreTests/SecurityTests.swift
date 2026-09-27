import XCTest
import Darwin
@testable import OctoCore

final class SecurityTests: XCTestCase {
    func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func mode(_ url: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }
    func testArchivePermissionsMigrationBackupExclusionAndAtomicReplacement() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let originalParentMode = try mode(root)
        let parent = root.appendingPathComponent("private")
        let store = WorkspaceStore(fileURL: parent.appendingPathComponent("workspace.json"))
        try store.save(WorkspaceArchive())
        XCTAssertEqual(try mode(parent), 0o700); XCTAssertEqual(try mode(store.fileURL), 0o600)
        XCTAssertEqual(try store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path)
        _ = try store.load()
        XCTAssertEqual(try mode(store.fileURL), 0o600)
        try store.save(WorkspaceArchive(projects: [.init(name: "fixture", rootPath: "/tmp/fixture")]))
        XCTAssertEqual(try store.load().projects.count, 1)
        XCTAssertEqual(try mode(store.fileURL), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["workspace.json"])
        XCTAssertEqual(try mode(root), originalParentMode, "Do not chmod unrelated custom parents")
    }
    func testArchiveRejectsRepositoryAndLinksWithoutChangingTargets() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("renamed.json"))
        XCTAssertThrowsError(try store.save(WorkspaceArchive()))
        XCTAssertThrowsError(try store.load())
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        let outside = root.appendingPathComponent("target")
        try Data("unchanged".utf8).write(to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outside.path)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: outside)
        XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save(WorkspaceArchive()))
        XCTAssertEqual(try Data(contentsOf: outside), Data("unchanged".utf8))
        XCTAssertEqual(try mode(outside), 0o644)
    }
    func testPrivateSocketDirectoryIsShortOwnedAndRemoved() throws {
        var directory: PrivateTemporaryDirectory? = try PrivateTemporaryDirectory()
        let path = try XCTUnwrap(directory?.url)
        XCTAssertEqual(try mode(path), 0o700)
        XCTAssertLessThan(path.appendingPathComponent("nvim.sock").path.utf8.count, 104)
        try Data().write(to: path.appendingPathComponent("fixture"))
        directory = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    func testProcessDrainsBothPipesAndPreservesArgumentsAndInput() async throws {
        let script = "import sys; data=sys.stdin.buffer.read(); sys.stdout.buffer.write(data); sys.stdout.write(sys.argv[1]); sys.stderr.write('e'*100000)"
        let input = Data(repeating: 120, count: 200_000)
        let value = "space ' quote ; $(not-a-command)"
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script, value], directory: URL(fileURLWithPath: "/tmp"), input: input)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, input + Data(value.utf8))
        XCTAssertEqual(result.error.count, 100_000)
    }
    func testProcessOutputLimitAndDeadline() async throws {
        for (script, limit, timeout) in [("import sys; sys.stdout.write('x'*1000000)", 4096, 5.0), ("import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)", 4096, 0.3)] {
            let start = Date()
            do {
                _ = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script], directory: URL(fileURLWithPath: "/tmp"), timeout: timeout, outputLimit: limit)
                XCTFail("Expected resource limit failure")
            } catch { XCTAssertTrue(error is ProcessFailure) }
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        }
    }
    func testCancellationStopsProcessGroupIncludingDescendant() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("pid")
        let script = "import subprocess,sys,time,signal; p=subprocess.Popen(['/bin/sleep','30']); open(sys.argv[1],'w').write(str(p.pid)); signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)"
        let task = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script, pidFile.path], directory: root) }
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: pidFile.path) { break }; try await Task.sleep(for: .milliseconds(20)) }
        let childPID = try XCTUnwrap(Int32(String(contentsOf: pidFile)))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        for _ in 0..<100 { if kill(childPID, 0) < 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
    func testUnsafeCustomParentAndHardLinkedArchiveAreRejected() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("state.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
        XCTAssertThrowsError(try store.save(WorkspaceArchive()))
        XCTAssertEqual(try mode(root), 0o777)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let target = root.appendingPathComponent("target.json")
        try JSONEncoder().encode(WorkspaceArchive()).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        try FileManager.default.linkItem(at: target, to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try mode(target), 0o644)
    }
    func testChildDoesNotInheritUnrelatedFileDescriptors() async throws {
        let descriptor = Darwin.open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        _ = fcntl(descriptor, F_SETFD, 0)
        let script = "import os,sys;\ntry: os.fstat(int(sys.argv[1])); sys.exit(1)\nexcept OSError: sys.exit(0)"
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script, String(descriptor)], directory: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(result.status, 0)
    }
}
