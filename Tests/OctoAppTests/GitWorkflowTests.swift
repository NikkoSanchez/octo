import XCTest
import OctoCore
import OctoGit
@testable import OctoApp

@MainActor final class GitWorkflowTests: XCTestCase {
    private func repository() async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("octo-git-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let git = try XCTUnwrap(Executables.find("git"))
        for arguments in [["init", "--quiet", "-b", "main"], ["config", "user.name", "Octo Test"], ["config", "user.email", "octo@example.invalid"],
                          ["config", "commit.gpgsign", "false"], ["config", "core.hooksPath", root.appendingPathComponent(".git/no-hooks").path]] {
            let result = try await ProcessRunner.run(git, arguments: arguments, directory: root)
            XCTAssertEqual(result.status, 0)
        }
        return root
    }

    func testStageCommitAndFollowUpThroughTheWorkflow() async throws {
        let root = try await repository()
        try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let review = ReviewModel(), git = GitWorkflow(), id = UUID()
        let target = GitWorkflow.Target(projectID: id, root: root.path)
        await review.refresh(projectID: id, root: root.path)
        await git.load(target)
        XCTAssertEqual(review.files.filter(\.hasWorking).count, 2)

        let a = try XCTUnwrap(review.files.first { $0.path == "a.txt" })
        // Two requests made back to back, as from two clicks, run in the order made. (`async let`
        // would not do: it does not fix which child starts first.)
        let first = Task { await git.stage([a], in: target, review: review) }
        let second = Task { await git.commit(message: "Add a", in: target, review: review) }
        await first.value; await second.value
        XCTAssertNil(git.problem)
        XCTAssertEqual(git.lastCommit?.subject, "Add a")
        XCTAssertEqual(review.files.map(\.path), ["b.txt"], "Only the staged file was committed")
        XCTAssertEqual(git.status?.branch, "main")
        XCTAssertFalse(git.status?.canPush ?? true, "No remote: Push stays disabled")

        await git.push(in: target, review: review)
        XCTAssertEqual(git.pushProblem?.title.contains("saved locally"), true)
        XCTAssertNotNil(git.pushProblem?.hint)

        await git.commit(message: "Nothing staged", in: target, review: review)
        XCTAssertNotNil(git.problem, "Git's refusal is shown")
        XCTAssertEqual(git.lastCommit?.subject, "Add a")
    }

    func testResultsForASupersededCheckoutAreDropped() async throws {
        let first = try await repository(), second = try await repository()
        try "x\n".write(to: first.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        let review = ReviewModel(), git = GitWorkflow(), id = UUID()
        let old = GitWorkflow.Target(projectID: id, root: first.path), new = GitWorkflow.Target(projectID: id, root: second.path)
        await review.refresh(projectID: id, root: first.path)
        await git.load(old)
        let file = try XCTUnwrap(review.files.first)
        git.drafts[first.path] = "draft"
        await git.load(new)
        await review.refresh(projectID: id, root: second.path)
        await git.stage([file], in: old, review: review)
        XCTAssertTrue(review.represents(projectID: id, root: second.path), "A late action never switches Changes back")
        XCTAssertNil(git.problem)
        XCTAssertEqual(git.drafts[first.path], "draft", "Commit drafts are kept per checkout")
        let status = try await GitService().changes(root: first.path)
        XCTAssertFalse(status.contains(where: \.hasStaged), "An action for a checkout no longer shown is not run")
    }

    func testABranchSwitchInATerminalRefreshesWithoutLooping() async throws {
        let root = try await repository()
        try "one\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let executable = try XCTUnwrap(Executables.find("git"))
        for arguments in [["add", "--all"], ["commit", "--quiet", "-m", "base"]] {
            _ = try await ProcessRunner.run(executable, arguments: arguments, directory: root)
        }
        let review = ReviewModel(), git = GitWorkflow(), id = UUID(), target = GitWorkflow.Target(projectID: id, root: root.path)
        var changes = 0
        git.onExternalChange = {
            changes += 1
            Task { await review.refresh(projectID: id, root: root.path); await git.load(target) }
        }
        await review.refresh(projectID: id, root: root.path)
        await git.load(target)
        XCTAssertEqual(review.branch, "main")

        _ = try await ProcessRunner.run(executable, arguments: ["switch", "--quiet", "-c", "feature/terminal"], directory: root)
        for _ in 0..<60 where review.branch != "feature/terminal" || git.status?.branch != "feature/terminal" { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(review.branch, "feature/terminal")
        XCTAssertEqual(git.status?.branch, "feature/terminal")
        // Octo's own refresh only reads, so it must not trigger another one.
        let settled = changes
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertEqual(changes, settled)
    }

    func testPushProblemsExplainTheNextStepAndKeepCommits() {
        let rejected = GitWorkflow.pushProblem(ProcessFailure.exited(" ! [rejected] main -> main (fetch first)"), destination: "origin/main", commits: 2)
        XCTAssertEqual(rejected.title, "Couldn't push to origin/main. Your 2 commits are saved locally.")
        XCTAssertTrue(rejected.hint?.contains("Pull or rebase") == true)
        let auth = GitWorkflow.pushProblem(ProcessFailure.exited("fatal: could not read Username for 'https://github.com': terminal prompts disabled"), destination: "origin", commits: 1)
        XCTAssertTrue(auth.title.hasSuffix("Your commit is saved locally."))
        XCTAssertTrue(auth.hint?.contains("credential") == true)
        let offline = GitWorkflow.pushProblem(ProcessFailure.exited("fatal: unable to access 'https://x/': Could not resolve host: x"), destination: "origin", commits: 1)
        XCTAssertTrue(offline.hint?.contains("network") == true)
        XCTAssertTrue(GitWorkflow.pushProblem(ProcessFailure.timedOut, destination: "origin", commits: 0).hint?.contains("five minutes") == true)
        XCTAssertEqual(offline.detail, "fatal: unable to access 'https://x/': Could not resolve host: x")
    }

    func testChangesShowEveryFileWithNothingSelectedAndAClickScrolls() async throws {
        let root = try await repository()
        for name in ["a.txt", "b.txt"] { try "base\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let executable = try XCTUnwrap(Executables.find("git"))
        for arguments in [["add", "--all"], ["commit", "--quiet", "-m", "base"]] { _ = try await ProcessRunner.run(executable, arguments: arguments, directory: root) }
        try "staged\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        _ = try await ProcessRunner.run(executable, arguments: ["add", "b.txt"], directory: root)
        try "staged\nmore\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "changed\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let review = ReviewModel(), id = UUID()
        await review.refresh(projectID: id, root: root.path)

        // Staged first, then Unstaged; a partly staged file appears in both.
        XCTAssertEqual(review.changeSnapshots.map { "\($0.scope.rawValue):\($0.path)" }, ["staged:b.txt", "working:a.txt", "working:b.txt"])
        XCTAssertNil(review.selectedPath, "Nothing is selected by default")
        XCTAssertEqual(review.snapshot?.path, "b.txt", "The header shows the file at the top")

        let a = try XCTUnwrap(review.files.first { $0.path == "a.txt" })
        let request = review.revealFileRequest
        await review.select(a, scope: .working, projectID: id, root: root.path)
        XCTAssertEqual(review.selectedPath, "a.txt")
        XCTAssertEqual(review.revealFile, 1)
        XCTAssertEqual(review.revealFileRequest, request + 1)
        XCTAssertEqual(review.snapshot?.id, review.changeSnapshots[1].id, "Chosen from the loaded diffs, without another read")

        // Scrolling moves the current file, and a chosen row follows it.
        review.showVisibleFile(2)
        XCTAssertEqual(review.snapshot?.path, "b.txt"); XCTAssertEqual(review.snapshot?.scope, .working)
        XCTAssertEqual(review.selectedPath, "b.txt"); XCTAssertEqual(review.scope, .working)

        // A refresh with the same changes keeps the current file and the documents' identity.
        let ids = review.changeSnapshots.map(\.id)
        await review.refresh(projectID: id, root: root.path)
        XCTAssertEqual(review.changeSnapshots.map(\.id), ids)
        XCTAssertEqual(review.snapshot?.path, "b.txt"); XCTAssertEqual(review.snapshot?.scope, .working)
    }

    func testPullHintsNameTheNextStep() {
        XCTAssertTrue(GitWorkflow.pullHint("fatal: Not possible to fast-forward, aborting.").contains("Merge or rebase in the terminal"))
        XCTAssertTrue(GitWorkflow.pullHint("error: Your local changes to the following files would be overwritten by merge").contains("Commit or stash"))
        XCTAssertTrue(GitWorkflow.pullHint("fatal: unable to access 'https://x/'").contains("network"))
    }

    func testDiscardConfirmationNamesWhatIsLost() {
        let one = GitHeader.discardMessage([ChangedFile(path: "a.txt", indexStatus: "M", worktreeStatus: "M")])
        XCTAssertTrue(one.hasPrefix("Staged changes are kept."))
        XCTAssertTrue(one.contains("can't recover"))
        let many = GitHeader.discardMessage([ChangedFile(path: "a.txt", indexStatus: " ", worktreeStatus: "M"),
                                             ChangedFile(path: "new.txt", indexStatus: "?", worktreeStatus: "?")])
        XCTAssertTrue(many.contains("restores 1 file to their staged or committed versions and deletes 1 untracked file:"), many)
        XCTAssertTrue(many.contains("a.txt\nnew.txt"))
    }
}
