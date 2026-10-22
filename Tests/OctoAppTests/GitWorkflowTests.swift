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
        // Two requests made together run in order.
        async let first: Void = git.stage([a], in: target, review: review)
        async let second: Void = git.commit(message: "Add a", in: target, review: review)
        _ = await (first, second)
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
