import Foundation
import OctoCore
import OctoGit

/// A failed Git action: what happened, what to do next, and Git's own output.
struct GitProblem: Equatable {
    var title: String
    var hint: String?
    var detail: String?
}

/// Native Git actions for the Changes tab: staging, commits, stashes, push and pull requests.
/// Actions run one at a time in the order requested, each against the project and checkout it
/// captured. Results for a superseded checkout are dropped. Nothing is pushed or published
/// except by an explicit Push or Create Pull Request.
@MainActor final class GitWorkflow: ObservableObject {
    struct Target: Equatable {
        var projectID: UUID
        var root: String
    }
    enum Sheet: Identifiable, Equatable {
        case stashes, newStash, pullRequest
        var id: Self { self }
    }
    @Published private(set) var status: UpstreamStatus?
    @Published private(set) var stashes: [GitStash] = []
    /// The running action, for the progress indicator.
    @Published private(set) var activity: String?
    @Published var problem: GitProblem?
    /// Kept apart from other errors: the banner offers Retry and says the commits are safe.
    @Published var pushProblem: GitProblem?
    @Published private(set) var lastCommit: CommitSummary?
    @Published private(set) var notice: String?
    /// Open pull requests by checkout and branch, filled when looked up or created.
    @Published private(set) var pullRequests: [String: PullRequest] = [:]
    @Published var sheet: Sheet?
    /// Files awaiting confirmation before their unstaged edits are discarded.
    @Published var discardRequest: [ChangedFile]?
    /// Commit message drafts by checkout. Not published: the composer owns the live text.
    var drafts: [String: String] = [:]
    private(set) var target: Target?
    private let git = GitService()
    /// Called, debounced, when the checkout's Git directory changes outside an Octo action: a branch
    /// switched, a commit made or files staged from a terminal or agent.
    var onExternalChange: (() -> Void)?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedDirectory: String?
    private var debounce: Task<Void, Never>?
    private var tail: Task<Bool, Never>?
    private var noticeTask: Task<Void, Never>?

    func pullRequest(for target: Target) -> PullRequest? {
        status?.branch.flatMap { pullRequests[target.root + "\u{0}" + $0] }
    }
    /// Reads upstream and stash state. A new checkout starts without the previous one's results.
    func load(_ target: Target) async {
        if self.target != target {
            self.target = target
            status = nil; stashes = []; problem = nil; pushProblem = nil; lastCommit = nil; notice = nil; sheet = nil; discardRequest = nil
            await watch(target)
        }
        let status = try? await git.upstreamStatus(root: target.root)
        let stashes = (try? await git.stashes(root: target.root)) ?? []
        guard self.target == target else { return }
        if self.status != status { self.status = status }
        if self.stashes != stashes { self.stashes = stashes }
    }

    /// Git replaces HEAD and index by renaming lock files, which changes the directory's entries.
    /// Refreshing only reads (`--no-optional-locks`), so it cannot retrigger the watcher.
    private func watch(_ target: Target) async {
        let directory = try? await git.gitDirectory(root: target.root)
        guard self.target == target, directory != watchedDirectory else { return }
        watcher?.cancel(); watcher = nil; watchedDirectory = directory
        guard let directory else { return }
        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else { watchedDirectory = nil; return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.gitDirectoryChanged() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }
    private func gitDirectoryChanged() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            // An Octo action refreshes when it finishes.
            guard !Task.isCancelled, let self, self.activity == nil else { return }
            self.onExternalChange?()
        }
    }

    /// Runs after any earlier action finishes, then refreshes Changes and upstream state.
    @discardableResult
    private func perform(_ label: String, failure: String, in target: Target, review: ReviewModel,
                         _ body: @escaping () async throws -> Void) async -> Bool {
        let previous = tail
        let task = Task { @MainActor () -> Bool in
            _ = await previous?.value
            guard self.target == target else { return false }
            self.activity = label; self.problem = nil
            var succeeded = false
            do { try await body(); succeeded = true }
            catch {
                if self.target == target { self.problem = GitProblem(title: failure, hint: nil, detail: error.localizedDescription) }
            }
            if review.represents(projectID: target.projectID, root: target.root) {
                await review.refresh(projectID: target.projectID, root: target.root)
            }
            await self.load(target)
            if self.target == target { self.activity = nil }
            return succeeded
        }
        tail = task
        return await task.value
    }
    private func announce(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Index

    func stage(_ files: [ChangedFile], in target: Target, review: ReviewModel) async {
        let paths = files.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        guard !paths.isEmpty else { return }
        await perform("Staging…", failure: files.count == 1 ? "Couldn't stage \(Self.name(files[0]))" : "Couldn't stage changes", in: target, review: review) {
            try await self.git.stage(paths, root: target.root)
        }
    }
    func unstage(_ files: [ChangedFile], in target: Target, review: ReviewModel) async {
        guard !files.isEmpty else { return }
        await perform("Unstaging…", failure: files.count == 1 ? "Couldn't unstage \(Self.name(files[0]))" : "Couldn't unstage changes", in: target, review: review) {
            try await self.git.unstage(files, root: target.root)
        }
    }
    func applyHunk(_ snapshot: ReviewSnapshot, hunk: Int, in target: Target, review: ReviewModel) async {
        let staging = snapshot.scope != .staged
        await perform(staging ? "Staging hunk…" : "Unstaging hunk…", failure: staging ? "Couldn't stage this hunk" : "Couldn't unstage this hunk",
                      in: target, review: review) {
            try await self.git.applyHunk(snapshot, hunk: hunk, root: target.root)
        }
    }
    /// Called only from the discard confirmation.
    func discard(_ files: [ChangedFile], in target: Target, review: ReviewModel) async {
        guard !files.isEmpty else { return }
        if await perform("Discarding…", failure: "Couldn't discard changes", in: target, review: review, {
            try await self.git.discardUnstaged(files, root: target.root)
        }) { announce("Unstaged changes discarded. Staged changes kept.") }
    }

    // MARK: Commit and publish

    func commit(message: String, in target: Target, review: ReviewModel) async {
        var summary: CommitSummary?
        if await perform("Committing…", failure: "Couldn't commit", in: target, review: review, {
            summary = try await self.git.commit(message: message, root: target.root)
        }) {
            lastCommit = summary; drafts[target.root] = nil
        }
    }
    func push(in target: Target, review: ReviewModel) async {
        let destination = status?.upstream ?? status?.pushRemote ?? "the remote"
        let commits = status?.ahead ?? 0
        var failure: Error?
        await perform("Pushing…", failure: "Couldn't push", in: target, review: review) {
            do { try await self.git.push(root: target.root) } catch { failure = error }
        }
        guard self.target == target else { return }
        if let failure {
            pushProblem = Self.pushProblem(failure, destination: destination, commits: commits)
        } else if problem == nil {
            pushProblem = nil
            announce("Pushed to \(status?.upstream ?? destination).")
        }
    }
    func fetch(in target: Target, review: ReviewModel) async {
        if await perform("Fetching…", failure: "Couldn't fetch", in: target, review: review, {
            try await self.git.fetch(root: target.root)
        }) { announce("Fetched from \(status?.upstreamRemote ?? status?.pushRemote ?? "the remote").") }
    }
    /// Push failures keep the local commits; the hint says what usually fixes each kind.
    static func pushProblem(_ error: Error, destination: String, commits: Int) -> GitProblem {
        let detail = error.localizedDescription, lower = detail.lowercased()
        let saved = commits == 1 ? "Your commit is saved locally." : commits > 1 ? "Your \(commits) commits are saved locally." : "Your commits are saved locally."
        let hint: String
        if lower.contains("non-fast-forward") || lower.contains("fetch first") || lower.contains("[rejected]") {
            hint = "The remote branch has commits this checkout doesn't. Pull or rebase in the terminal, then push again."
        } else if lower.contains("terminal prompts disabled") || lower.contains("authentication failed")
                    || lower.contains("permission denied") || lower.contains("could not read username") {
            hint = "Git needs credentials it can use without a terminal, such as a credential helper or an SSH agent."
        } else if lower.contains("hook") {
            hint = "A pre-push hook stopped the push. Its output is below."
        } else if case .timedOut? = error as? ProcessFailure {
            hint = "The push did not finish within five minutes."
        } else if lower.contains("could not resolve host") || lower.contains("unable to access") || lower.contains("could not read from remote") {
            hint = "Check your network connection and access to the remote, then retry."
        } else {
            hint = "Fix the problem below, then retry."
        }
        return GitProblem(title: "Couldn't push to \(destination). \(saved)", hint: hint, detail: detail)
    }

    // MARK: Stashes

    @discardableResult
    func stash(name: String, includeUntracked: Bool, in target: Target, review: ReviewModel) async -> Bool {
        let succeeded = await perform("Stashing…", failure: "Couldn't stash changes", in: target, review: review) {
            try await self.git.stash(message: name, includeUntracked: includeUntracked, root: target.root)
        }
        if succeeded { announce("Stashed “\(name)”.") }
        return succeeded
    }
    @discardableResult
    func apply(_ stash: GitStash, pop: Bool, in target: Target, review: ReviewModel) async -> Bool {
        let succeeded = await perform(pop ? "Popping stash…" : "Applying stash…", failure: pop ? "Couldn't pop “\(stash.message)”" : "Couldn't apply “\(stash.message)”",
                                      in: target, review: review) {
            try await self.git.applyStash(stash, pop: pop, root: target.root)
        }
        if succeeded { announce(pop ? "Stash popped. Changes restored." : "Stash applied. The saved copy is kept.") }
        else if var problem, self.target == target {
            problem.hint = (problem.detail ?? "").contains("--index")
                ? "The stash's staged changes conflict with the current index. Commit or stash your current changes first. The stash was kept."
                : "The stash was kept. Resolve any conflicts in the terminal, or commit or stash your current changes and try again."
            self.problem = problem
        }
        return succeeded
    }
    func drop(_ stash: GitStash, in target: Target, review: ReviewModel) async {
        if await perform("Dropping stash…", failure: "Couldn't drop “\(stash.message)”", in: target, review: review, {
            try await self.git.dropStash(stash, root: target.root)
        }) { announce("Stash dropped.") }
    }

    // MARK: Pull requests

    func lookUpPullRequest(in target: Target) async throws -> PullRequest? {
        guard let branch = status?.branch else { return nil }
        let request = try await PullRequests.open(branch: branch, root: target.root)
        if self.target == target { pullRequests[target.root + "\u{0}" + branch] = request }
        return request
    }
    func baseBranches(in target: Target) async -> (branches: [String], defaultBranch: String?) {
        guard let remote = status?.pushRemote else { return ([], nil) }
        guard let result = try? await git.remoteBranches(remote: remote, root: target.root) else { return ([], nil) }
        return (result.branches.filter { $0 != status?.branch }, result.defaultBranch)
    }
    /// One commit titles the pull request; several are listed in its description.
    func pullRequestDraft(base: String, in target: Target) async -> (title: String, body: String) {
        let branch = status?.branch ?? ""
        let remote = status?.pushRemote.map { $0 + "/" } ?? ""
        let subjects = (try? await git.commitSubjects(since: remote + base, root: target.root)) ?? []
        if subjects.count == 1 { return (subjects[0], "") }
        let title = branch.split(separator: "/").last.map { $0.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ") } ?? ""
        let body = subjects.isEmpty ? "" : "## Changes\n" + subjects.reversed().map { "- " + $0 }.joined(separator: "\n")
        return (title.prefix(1).uppercased() + title.dropFirst(), body)
    }
    func createPullRequest(title: String, body: String, base: String, draft: Bool, in target: Target) async throws -> PullRequest {
        guard let branch = status?.branch else { throw ProcessFailure.exited("Check out a branch first.") }
        let request = try await PullRequests.create(title: title, body: body, base: base, head: branch, draft: draft, root: target.root)
        if self.target == target { pullRequests[target.root + "\u{0}" + branch] = request }
        return request
    }

    static func name(_ file: ChangedFile) -> String { (file.path as NSString).lastPathComponent }
}
