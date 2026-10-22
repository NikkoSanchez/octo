import XCTest
import OctoCore
@testable import OctoGit

final class GitActionTests: XCTestCase {
    /// A repository with a fixture identity, no signing and no hooks from the user's configuration.
    private struct Repository {
        let root: URL
        let git: URL
        @discardableResult
        func run(_ arguments: [String], in directory: URL? = nil) async throws -> String {
            let result = try await ProcessRunner.run(git, arguments: arguments, directory: directory ?? root)
            XCTAssertEqual(result.status, 0, "git \(arguments.joined(separator: " ")): " + String(decoding: result.error, as: UTF8.self))
            return String(decoding: result.output, as: UTF8.self)
        }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        func commitAll(_ message: String) async throws {
            try await run(["add", "--all"]); try await run(["commit", "--quiet", "-m", message])
        }
    }
    private var cleanup: [URL] = []
    override func tearDown() {
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
        cleanup = []
    }
    private func makeRepository(bare: Bool = false) async throws -> Repository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cleanup.append(root)
        let repository = Repository(root: root, git: try XCTUnwrap(Executables.find("git")))
        try await repository.run(bare ? ["init", "--quiet", "--bare", "-b", "main"] : ["init", "--quiet", "-b", "main"])
        guard !bare else { return repository }
        for (key, value) in [("user.name", "Octo Test"), ("user.email", "octo@example.invalid"), ("commit.gpgsign", "false"),
                             ("core.hooksPath", root.appendingPathComponent(".git/no-hooks").path)] {
            try await repository.run(["config", key, value])
        }
        return repository
    }
    private let numbered = (1...30).map { "line \($0)" }

    func testPatchQuotesUnusualNamesAndKeepsMissingNewlineNote() throws {
        XCTAssertEqual(HunkPatch.quoted("a/plain name.txt"), "a/plain name.txt")
        XCTAssertEqual(HunkPatch.quoted("a/quote\"tab\t.txt"), "\"a/quote\\\"tab\\t.txt\"")
        XCTAssertEqual(HunkPatch.quoted("a/café\u{1}"), "\"a/café\\001\"")
        let lines = UnifiedDiffParser.parse("@@ -1,2 +1,2 @@\n same\n-old\n+new\n\\ No newline at end of file\n@@ -9 +9 @@\n-x\n+y\n")
        let ids = HunkPatch.hunkIDs(in: lines)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(HunkPatch.make(path: "f.txt", lines: lines, hunk: ids[0]),
                       "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -1,2 +1,2 @@\n same\n-old\n+new\n\\ No newline at end of file\n")
        XCTAssertEqual(HunkPatch.hunkID(containing: lines.last!.id, in: lines), ids[1])
        XCTAssertNil(HunkPatch.make(path: "f.txt", lines: lines, hunk: lines[1].id), "Only hunk headers start a patch")
    }

    func testHunkStagingChangesOnlyTheIndex() async throws {
        let repo = try await makeRepository()
        let path = "Sources/file with spaces.swift"
        try repo.write(path, numbered.joined(separator: "\n") + "\n")
        try await repo.commitAll("fixture")
        var edited = numbered; edited[1] = "first change"; edited[27] = "second change"
        let working = edited.joined(separator: "\n") + "\n"
        try repo.write(path, working)

        let service = GitService(), id = UUID()
        var changes = try await service.changes(root: repo.root.path)
        var file = try XCTUnwrap(changes.first)
        XCTAssertTrue(file.supportsHunkStaging(.working))
        let snapshot = try await service.snapshot(file: file, projectID: id, root: repo.root.path, scope: .working)
        let hunks = HunkPatch.hunkIDs(in: snapshot.lines)
        XCTAssertEqual(hunks.count, 2, "Changes 26 lines apart stay separate with five lines of context")
        try await service.applyHunk(snapshot, hunk: hunks[1], root: repo.root.path)

        let staged = try await repo.run(["diff", "--cached"])
        XCTAssertTrue(staged.contains("+second change")); XCTAssertFalse(staged.contains("+first change"))
        let unstaged = try await repo.run(["diff"])
        XCTAssertTrue(unstaged.contains("+first change")); XCTAssertFalse(unstaged.contains("+second change"))
        XCTAssertEqual(try repo.read(path), working, "Staging a hunk never touches the working tree")

        // The same hunk applied again no longer matches the index.
        do { try await service.applyHunk(snapshot, hunk: hunks[1], root: repo.root.path); XCTFail("Applied a stale hunk") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no longer matches")) }

        changes = try await service.changes(root: repo.root.path)
        file = try XCTUnwrap(changes.first)
        XCTAssertTrue(file.supportsHunkStaging(.staged))
        let stagedSnapshot = try await service.snapshot(file: file, projectID: id, root: repo.root.path, scope: .staged)
        try await service.applyHunk(stagedSnapshot, hunk: try XCTUnwrap(HunkPatch.hunkIDs(in: stagedSnapshot.lines).first), root: repo.root.path)
        let afterUnstage = try await repo.run(["diff", "--cached"])
        XCTAssertEqual(afterUnstage, "")
        XCTAssertEqual(try repo.read(path), working)
    }

    func testFileStagingDiscardAndCommitKeepTheirScopes() async throws {
        let repo = try await makeRepository()
        try repo.write("kept.txt", "base\n")
        try repo.write("renamed-from.txt", "rename me\n")
        try await repo.commitAll("fixture")
        let service = GitService(), root = repo.root.path

        // Staged content survives discarding a later unstaged edit to the same file.
        try repo.write("kept.txt", "staged\n")
        try await service.stage(["kept.txt"], root: root)
        try repo.write("kept.txt", "staged\nunstaged\n")
        try repo.write("new.txt", "untracked\n")
        var files = try await service.changes(root: root)
        try await service.discardUnstaged(files, root: root)
        XCTAssertEqual(try repo.read("kept.txt"), "staged\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("new.txt").path))
        files = try await service.changes(root: root)
        XCTAssertEqual(files.map(\.path), ["kept.txt"])
        XCTAssertEqual(files.first?.indexStatus, "M"); XCTAssertEqual(files.first?.worktreeStatus, " ")

        // A staged rename unstages both of its paths.
        try await repo.run(["mv", "renamed-from.txt", "renamed-to.txt"])
        files = try await service.changes(root: root)
        let rename = try XCTUnwrap(files.first { $0.indexStatus == "R" })
        XCTAssertEqual(rename.originalPath, "renamed-from.txt")
        try await service.unstage([rename], root: root)
        let afterRename = try await service.changes(root: root)
        XCTAssertEqual(afterRename.filter(\.hasStaged).map(\.path), ["kept.txt"])
        try await service.stage(["renamed-from.txt", "renamed-to.txt"], root: root)
        let renamed = try await service.changes(root: root).filter { $0.path.hasPrefix("renamed") }
        try await service.unstage(renamed, root: root)

        // Committing takes only the index; the message keeps a leading "#".
        try repo.write("kept.txt", "staged\nstill unstaged\n")
        let summary = try await service.commit(message: "#12 Keep staged edits\n\nBody line.\n", root: root)
        XCTAssertEqual(summary.subject, "#12 Keep staged edits")
        XCTAssertFalse(summary.hash.isEmpty)
        let committed = try await repo.run(["show", "HEAD:kept.txt"])
        XCTAssertEqual(committed, "staged\n")
        XCTAssertEqual(try repo.read("kept.txt"), "staged\nstill unstaged\n")
        let remaining = try await service.changes(root: root)
        XCTAssertFalse(remaining.contains { $0.hasStaged && $0.path == "kept.txt" })
        do { _ = try await service.commit(message: "  \n", root: root); XCTFail("Committed an empty message") } catch {}
    }

    func testUnstageBeforeFirstCommitAndLiteralPathspecs() async throws {
        let repo = try await makeRepository()
        try repo.write("*.txt", "star\n")
        try repo.write("other.txt", "other\n")
        let service = GitService(), root = repo.root.path
        try await service.stage(["*.txt"], root: root)
        var files = try await service.changes(root: root)
        XCTAssertEqual(files.filter(\.hasStaged).map(\.path), ["*.txt"], "A glob character names only that file")
        try await service.unstage(files.filter(\.hasStaged), root: root)
        files = try await service.changes(root: root)
        XCTAssertTrue(files.allSatisfy(\.isUntracked))
        let status = try await service.upstreamStatus(root: root)
        XCTAssertEqual(status.branch, "main"); XCTAssertFalse(status.hasCommits); XCTAssertFalse(status.canPush)
    }

    func testNamedStashesRestoreStagingAndDetectShiftedReferences() async throws {
        let repo = try await makeRepository()
        try repo.write("a.txt", "base\n")
        try await repo.commitAll("fixture")
        let service = GitService(), root = repo.root.path
        try repo.write("a.txt", "staged\n")
        try await service.stage(["a.txt"], root: root)
        try repo.write("a.txt", "staged\nworking\n")
        try repo.write("untracked.txt", "new\n")
        try await service.stash(message: "WIP: native Git actions", includeUntracked: true, root: root)
        let cleared = try await service.changes(root: root)
        XCTAssertTrue(cleared.isEmpty)

        var stashes = try await service.stashes(root: root)
        XCTAssertEqual(stashes.count, 1)
        XCTAssertEqual(stashes.first?.message, "WIP: native Git actions")
        XCTAssertEqual(stashes.first?.branch, "main")
        let first = try XCTUnwrap(stashes.first)

        try await service.applyStash(first, pop: false, root: root)
        var files = try await service.changes(root: root)
        let restored = try XCTUnwrap(files.first { $0.path == "a.txt" })
        XCTAssertEqual(restored.indexStatus, "M"); XCTAssertEqual(restored.worktreeStatus, "M")
        XCTAssertTrue(files.contains { $0.path == "untracked.txt" && $0.isUntracked })
        let index = try await repo.run(["show", ":a.txt"])
        XCTAssertEqual(index, "staged\n", "Apply restores what was staged")
        stashes = try await service.stashes(root: root)
        XCTAssertEqual(stashes.count, 1, "Apply keeps the stash")

        // A newer stash shifts stash@{0}; the captured entry must not act on it.
        try await service.stash(message: "Second", includeUntracked: true, root: root)
        do { try await service.dropStash(first, root: root); XCTFail("Dropped a shifted stash") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        stashes = try await service.stashes(root: root)
        XCTAssertEqual(stashes.map(\.message), ["Second", "WIP: native Git actions"])
        try await service.applyStash(stashes[0], pop: true, root: root)
        stashes = try await service.stashes(root: root)
        XCTAssertEqual(stashes.map(\.message), ["WIP: native Git actions"])
        files = try await service.changes(root: root)
        XCTAssertFalse(files.isEmpty)
        try await service.dropStash(stashes[0], root: root)
        stashes = try await service.stashes(root: root)
        XCTAssertTrue(stashes.isEmpty)
        do { try await service.stash(message: "Nothing", includeUntracked: false, root: root)
            try await service.stash(message: "Nothing", includeUntracked: false, root: root); XCTFail("Stashed nothing") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no changes")) }
    }

    func testPushPublishesThenTracksWithoutForcing() async throws {
        let remote = try await makeRepository(bare: true)
        let repo = try await makeRepository()
        let service = GitService(), root = repo.root.path
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("one")
        var status = try await service.upstreamStatus(root: root)
        XCTAssertNil(status.pushRemote); XCTAssertFalse(status.canPush)
        do { try await service.push(root: root); XCTFail("Pushed without a remote") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no remote")) }

        try await repo.run(["remote", "add", "origin", remote.root.path])
        try await repo.run(["checkout", "--quiet", "-b", "feature/native-git"])
        status = try await service.upstreamStatus(root: root)
        XCTAssertEqual(status.branch, "feature/native-git"); XCTAssertNil(status.upstream)
        XCTAssertTrue(status.publishes); XCTAssertEqual(status.ahead, 1); XCTAssertTrue(status.canPush)
        try await service.push(root: root)
        status = try await service.upstreamStatus(root: root)
        XCTAssertEqual(status.upstream, "origin/feature/native-git"); XCTAssertEqual(status.upstreamRemote, "origin")
        XCTAssertEqual(status.ahead, 0); XCTAssertFalse(status.canPush)

        try repo.write("a.txt", "two\n")
        try await repo.commitAll("two")
        status = try await service.upstreamStatus(root: root)
        XCTAssertEqual(status.ahead, 1); XCTAssertTrue(status.canPush)
        try await service.push(root: root)
        let remoteHead = try await remote.run(["rev-parse", "refs/heads/feature/native-git"])
        let localHead = try await repo.run(["rev-parse", "HEAD"])
        XCTAssertEqual(remoteHead, localHead)

        // A diverged remote is rejected, never overwritten; the local commit stays.
        try await repo.run(["reset", "--quiet", "--hard", "HEAD~1"])
        try repo.write("a.txt", "diverged\n")
        try await repo.commitAll("diverged")
        let diverged = try await repo.run(["rev-parse", "HEAD"])
        do { try await service.push(root: root); XCTFail("Pushed over a diverged remote") } catch {}
        let localAfter = try await repo.run(["rev-parse", "HEAD"])
        let remoteAfter = try await remote.run(["rev-parse", "refs/heads/feature/native-git"])
        XCTAssertEqual(localAfter, diverged)
        XCTAssertEqual(remoteAfter, remoteHead)
        let branches = try await service.remoteBranches(remote: "origin", root: root)
        XCTAssertEqual(branches.branches, ["feature/native-git"])
    }

    func testPullFastForwardsOnlyAndRefusesDivergedOrConflictingUpdates() async throws {
        let remote = try await makeRepository(bare: true)
        let repo = try await makeRepository(), other = try await makeRepository()
        let service = GitService()
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("one")
        try await repo.run(["remote", "add", "origin", remote.root.path])
        do { try await service.pull(root: repo.root.path); XCTFail("Pulled without an upstream") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Push it first")) }
        try await service.push(root: repo.root.path)

        // Another clone pushes a commit; this checkout is now behind.
        try await other.run(["remote", "add", "origin", remote.root.path])
        try await other.run(["fetch", "--quiet", "origin"])
        try await other.run(["switch", "--quiet", "-C", "main", "origin/main"])
        try other.write("a.txt", "one\ntwo\n")
        try await other.commitAll("two")
        try await other.run(["push", "--quiet", "origin", "main"])
        try await service.fetch(root: repo.root.path)
        var status = try await service.upstreamStatus(root: repo.root.path)
        XCTAssertEqual(status.behind, 1); XCTAssertEqual(status.ahead, 0)

        // A local edit to the same file blocks the update without touching anything.
        try repo.write("a.txt", "local edit\n")
        do { try await service.pull(root: repo.root.path); XCTFail("Pulled over local edits") } catch {}
        XCTAssertEqual(try repo.read("a.txt"), "local edit\n")
        try await repo.run(["checkout", "--", "a.txt"])

        try await service.pull(root: repo.root.path)
        XCTAssertEqual(try repo.read("a.txt"), "one\ntwo\n")
        status = try await service.upstreamStatus(root: repo.root.path)
        XCTAssertEqual(status.behind, 0)

        // Diverged: both sides have a new commit. Pull refuses and leaves HEAD where it was.
        try other.write("a.txt", "one\ntwo\nthree\n")
        try await other.commitAll("three")
        try await other.run(["push", "--quiet", "origin", "main"])
        try repo.write("b.txt", "local\n")
        try await repo.commitAll("local")
        let head = try await repo.run(["rev-parse", "HEAD"])
        do { try await service.pull(root: repo.root.path); XCTFail("Merged a diverged branch") } catch {}
        let after = try await repo.run(["rev-parse", "HEAD"])
        XCTAssertEqual(after, head)
        let merging = FileManager.default.fileExists(atPath: repo.root.appendingPathComponent(".git/MERGE_HEAD").path)
        XCTAssertFalse(merging, "No merge is left in progress")
    }

    func testAllChangesLoadInOrderWithALineLimit() async throws {
        let repo = try await makeRepository()
        for name in ["a", "b", "c"] { try repo.write("\(name).txt", "base\n") }
        try await repo.commitAll("base")
        try repo.write("a.txt", (1...6).map { "a\($0)" }.joined(separator: "\n") + "\n")
        try await repo.run(["add", "a.txt"])
        try repo.write("b.txt", "changed\n")
        try repo.write("c.txt", "changed\n")
        try repo.write("new.txt", "untracked\n")
        let service = GitService(), root = repo.root.path
        let files = try await service.changes(root: root)
        let entries = files.filter(\.hasStaged).map { (file: $0, scope: DiffScope.staged) } + files.filter(\.hasWorking).map { (file: $0, scope: DiffScope.working) }
        let all = await service.snapshots(entries, projectID: UUID(), root: root)
        XCTAssertEqual(all.map(\.path), ["a.txt", "b.txt", "c.txt", "new.txt"])
        XCTAssertEqual(all.map(\.scope), [.staged, .working, .working, .working])
        XCTAssertTrue(all.allSatisfy { !$0.lines.isEmpty && $0.notice == nil })

        // Past the limit, later files carry the deferred notice instead of their lines.
        let limited = await service.snapshots(entries, projectID: UUID(), root: root, lineLimit: 5)
        XCTAssertFalse(limited[0].lines.isEmpty, "The file that crosses the limit is shown whole")
        XCTAssertEqual(limited.dropFirst().map(\.notice), Array(repeating: GitService.deferredNotice, count: 3))
        // An unreadable file reports its error without hiding the rest.
        let broken = entries + [(file: ChangedFile(path: "../outside", indexStatus: "?", worktreeStatus: "?"), scope: DiffScope.working)]
        let withError = await service.snapshots(broken, projectID: UUID(), root: root)
        XCTAssertEqual(withError.count, 5)
        XCTAssertNotNil(withError.last?.notice)
        XCTAssertFalse(withError[1].lines.isEmpty)
    }

    func testParsesTrackingAndStashSubjects() {
        XCTAssertTrue(GitService.parseTrack("ahead 2, behind 1") == (2, 1, false))
        XCTAssertTrue(GitService.parseTrack("behind 3") == (0, 3, false))
        XCTAssertTrue(GitService.parseTrack("gone") == (0, 0, true))
        XCTAssertTrue(GitService.parseTrack("") == (0, 0, false))
        let stashes = GitService.parseStashes("abc\u{1f}stash@{0}\u{1f}1700000000\u{1f}On feat/x: Name: with colon\ndef\u{1f}stash@{1}\u{1f}1700000001\u{1f}WIP on (no branch): 1234567 subject\nbad line\n")
        XCTAssertEqual(stashes.map(\.message), ["Name: with colon", "1234567 subject"])
        XCTAssertEqual(stashes.map(\.branch), ["feat/x", nil])
        XCTAssertEqual(stashes.map(\.reference), ["stash@{0}", "stash@{1}"])
        XCTAssertEqual(PullRequests.number(from: "https://github.com/o/r/pull/42"), 42)
        XCTAssertNil(PullRequests.number(from: "https://github.com/o/r"))
    }
}
