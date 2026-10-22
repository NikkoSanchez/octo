import Foundation
import OctoCore

/// The current branch's relation to its upstream, for Push and Create PR.
public struct UpstreamStatus: Equatable, Sendable {
    /// Nil while HEAD is detached.
    public var branch: String?
    /// For example `origin/main`; nil when the branch tracks nothing.
    public var upstream: String?
    public var upstreamRemote: String?
    /// Commits to push. Without a live upstream, commits that no remote-tracking branch contains.
    public var ahead = 0
    public var behind = 0
    /// The upstream is configured but its remote branch no longer exists.
    public var upstreamGone = false
    public var remotes: [String] = []
    public var hasCommits = false
    public init(branch: String? = nil, upstream: String? = nil, upstreamRemote: String? = nil, ahead: Int = 0, behind: Int = 0,
                upstreamGone: Bool = false, remotes: [String] = [], hasCommits: Bool = false) {
        self.branch = branch; self.upstream = upstream; self.upstreamRemote = upstreamRemote; self.ahead = ahead; self.behind = behind
        self.upstreamGone = upstreamGone; self.remotes = remotes; self.hasCommits = hasCommits
    }
    /// Where Push sends the branch: its upstream's remote, else origin, else the only remote.
    public var pushRemote: String? {
        upstreamRemote ?? (remotes.contains("origin") ? "origin" : remotes.count == 1 ? remotes[0] : nil)
    }
    /// A branch without a live upstream is published (and then tracked) on its first push.
    public var publishes: Bool { upstream == nil || upstreamGone }
    public var canPush: Bool { branch != nil && hasCommits && pushRemote != nil && (publishes || ahead > 0) }
}

public struct GitStash: Identifiable, Equatable, Sendable {
    public var id: String { commit }
    public var index: Int
    /// The stash commit, checked again before Apply, Pop or Drop because `stash@{n}` shifts.
    public var commit: String
    public var message: String
    public var branch: String?
    public var date: Date
    public var reference: String { "stash@{\(index)}" }
    public init(index: Int, commit: String, message: String, branch: String?, date: Date) {
        self.index = index; self.commit = commit; self.message = message; self.branch = branch; self.date = date
    }
}

public struct CommitSummary: Equatable, Sendable {
    public var hash: String
    public var subject: String
    public init(hash: String, subject: String) { self.hash = hash; self.subject = subject }
}

/// Index, commit, stash and publication actions. Each takes explicit paths or refs as argument
/// arrays; pathspecs are literal, so a file named `*` or `:(top)` means only itself.
extension GitService {
    private static let literal = "--literal-pathspecs"
    /// Pushes and fetches wait on the network and on hooks; commits wait on hooks and signing.
    static let networkTimeout: TimeInterval = 300

    /// The checkout's Git directory (a linked worktree's own directory), whose HEAD and index change
    /// when a branch is switched, a commit is made or files are staged from any terminal.
    public func gitDirectory(root: String) async throws -> String {
        try await text(["rev-parse", "--absolute-git-dir"], root: root)
    }
    func hasHead(_ root: String) async -> Bool {
        ((try? await git(["rev-parse", "--verify", "--quiet", "HEAD"], root: root))?.status ?? 1) == 0
    }
    private func checked(_ paths: [String]) throws -> [String] {
        guard paths.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") }) else { throw ProcessFailure.exited("File path is outside this checkout.") }
        return paths
    }

    // MARK: Index

    /// Stages the whole file, including deletions and untracked files.
    public func stage(_ paths: [String], root: String) async throws {
        guard !paths.isEmpty else { return }
        _ = try await text([Self.literal, "add", "--all", "--"] + checked(paths), root: root)
    }
    /// Returns the files' index entries to HEAD, keeping their working-tree contents.
    public func unstage(_ files: [ChangedFile], root: String) async throws {
        let paths = try checked(files.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) })
        guard !paths.isEmpty else { return }
        if await hasHead(root) { _ = try await text([Self.literal, "restore", "--staged", "--"] + paths, root: root) }
        // Before the first commit there is no HEAD to restore from: unstaging removes the entry.
        else { _ = try await text([Self.literal, "rm", "--cached", "--quiet", "-r", "--ignore-unmatch", "--"] + paths, root: root) }
    }
    /// Discards unstaged edits by restoring the working tree from the index, so staged changes stay.
    /// Untracked files are deleted. The caller confirms first: Git cannot recover these edits.
    public func discardUnstaged(_ files: [ChangedFile], root: String) async throws {
        let tracked = try checked(files.filter { !$0.isUntracked && $0.hasWorking }.map(\.path))
        let untracked = try checked(files.filter(\.isUntracked).map(\.path))
        if !tracked.isEmpty { _ = try await text([Self.literal, "restore", "--worktree", "--"] + tracked, root: root) }
        if !untracked.isEmpty { _ = try await text([Self.literal, "clean", "--force", "--quiet", "--"] + untracked, root: root) }
    }
    /// Stages one working-tree hunk, or unstages one staged hunk, changing only the index.
    public func applyHunk(_ snapshot: ReviewSnapshot, hunk id: Int, root: String) async throws {
        guard snapshot.workingDirectory == root, snapshot.scope != .file,
              let patch = HunkPatch.make(path: snapshot.path, lines: snapshot.lines, hunk: id) else {
            throw ProcessFailure.exited("This hunk can't be staged on its own. Stage the whole file instead.")
        }
        var arguments = ["apply", "--cached", "--whitespace=nowarn"]
        if snapshot.scope == .staged { arguments.append("--reverse") }
        let result = try await git(arguments + ["-"], root: root, input: Data(patch.utf8))
        guard result.status == 0 else {
            throw ProcessFailure.exited("This hunk no longer matches the index. Refresh Changes and try again.\n\n" + Self.message(result))
        }
    }

    // MARK: Commit

    /// Commits exactly what is staged. Repository hooks and signing settings apply as usual.
    public func commit(message: String, root: String) async throws -> CommitSummary {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProcessFailure.exited("Write a commit message first.") }
        // The message goes through standard input, so a leading "-" or "#" stays part of it.
        _ = try await text(["commit", "--cleanup=whitespace", "--file=-"], root: root, input: Data(message.utf8), timeout: Self.networkTimeout)
        let fields = try await text(["log", "-1", "--format=%h%x1f%s"], root: root).split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
        return CommitSummary(hash: fields.first.map(String.init) ?? "", subject: fields.count > 1 ? String(fields[1]) : "")
    }

    // MARK: Upstream and publication

    public func upstreamStatus(root: String) async throws -> UpstreamStatus {
        var status = UpstreamStatus()
        status.remotes = try await text(["remote"], root: root).split(separator: "\n").map(String.init)
        status.hasCommits = await hasHead(root)
        let symbolic = try await git(["symbolic-ref", "--quiet", "--short", "HEAD"], root: root)
        if symbolic.status == 0 { status.branch = String(decoding: symbolic.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let branch = status.branch, status.hasCommits else { return status }
        let ref = "refs/heads/" + branch
        let refs = try await text(["for-each-ref", "--format=%(refname)%1f%(upstream:short)%1f%(upstream:remotename)%1f%(upstream:track,nobracket)", ref], root: root)
        for line in refs.split(separator: "\n") {
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, fields[0] == ref, !fields[1].isEmpty else { continue }
            status.upstream = fields[1]; status.upstreamRemote = fields[2].isEmpty ? nil : fields[2]
            (status.ahead, status.behind, status.upstreamGone) = Self.parseTrack(fields[3])
        }
        if status.publishes {
            status.ahead = Int(try await text(["rev-list", "--count", "HEAD", "--not", "--remotes"], root: root)) ?? 0
        }
        return status
    }
    /// Parses `%(upstream:track,nobracket)`: "ahead 2, behind 1", "behind 3", "gone" or empty.
    nonisolated static func parseTrack(_ track: String) -> (ahead: Int, behind: Int, gone: Bool) {
        var ahead = 0, behind = 0
        for part in track.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else { continue }
            if words[0] == "ahead" { ahead = count } else if words[0] == "behind" { behind = count }
        }
        return (ahead, behind, track.trimmingCharacters(in: .whitespaces) == "gone")
    }
    /// Pushes the current branch only. A tracked branch uses the user's push configuration;
    /// an untracked one is published to `pushRemote` and starts tracking it. Never forces.
    public func push(root: String) async throws {
        let status = try await upstreamStatus(root: root)
        guard let branch = status.branch else { throw ProcessFailure.exited("Check out a branch before pushing.") }
        guard status.hasCommits else { throw ProcessFailure.exited("Commit before pushing.") }
        if !status.publishes {
            _ = try await text(["push"], root: root, timeout: Self.networkTimeout)
            return
        }
        guard let remote = status.pushRemote, !remote.hasPrefix("-") else {
            throw ProcessFailure.exited(status.remotes.isEmpty ? "This repository has no remote. Add one in the terminal, then push."
                                                             : "Several remotes and no origin. Choose one with git push -u in the terminal.")
        }
        _ = try await text(["push", "--set-upstream", remote, "refs/heads/\(branch):refs/heads/\(branch)"], root: root, timeout: Self.networkTimeout)
    }
    public func fetch(root: String) async throws {
        _ = try await text(["fetch", "--quiet"], root: root, timeout: Self.networkTimeout)
    }
    /// Branches on `remote` for a pull request base, and the remote's default branch when known.
    public func remoteBranches(remote: String, root: String) async throws -> (branches: [String], defaultBranch: String?) {
        let prefix = "refs/remotes/\(remote)/"
        let branches = try await text(["for-each-ref", "--format=%(refname)", "refs/remotes/\(remote)"], root: root).split(separator: "\n")
            .filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.filter { $0 != "HEAD" }
        let head = try await git(["symbolic-ref", "--quiet", prefix + "HEAD"], root: root)
        let target = String(decoding: head.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (branches, head.status == 0 && target.hasPrefix(prefix) ? String(target.dropFirst(prefix.count)) : nil)
    }

    /// Subjects of commits on HEAD that `base` lacks, newest first, to draft a pull request.
    public func commitSubjects(since base: String, root: String, limit: Int = 50) async throws -> [String] {
        try await text(["log", "--format=%s", "--max-count=\(limit)", "--end-of-options", "\(base)..HEAD", "--"], root: root)
            .split(separator: "\n").map(String.init)
    }

    // MARK: Stashes

    public func stashes(root: String) async throws -> [GitStash] {
        Self.parseStashes(try await text(["stash", "list", "--format=%H%x1f%gd%x1f%ct%x1f%s"], root: root))
    }
    nonisolated static func parseStashes(_ output: String) -> [GitStash] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, fields[1].hasPrefix("stash@{"), fields[1].hasSuffix("}"),
                  let index = Int(fields[1].dropFirst(7).dropLast()) else { return nil }
            // `stash push -m` records "On <branch>: <name>"; an unnamed stash "WIP on <branch>: <hash> <subject>".
            // Branch names cannot contain ":", so the first ": " ends the prefix.
            var message = fields[3], branch: String?
            if let separator = message.range(of: ": ") {
                let prefix = message[..<separator.lowerBound]
                for lead in ["WIP on ", "On "] where prefix.hasPrefix(lead) {
                    let name = String(prefix.dropFirst(lead.count))
                    branch = name == "(no branch)" ? nil : name
                    message = String(message[separator.upperBound...])
                    break
                }
            }
            return GitStash(index: index, commit: fields[0], message: message, branch: branch,
                            date: Date(timeIntervalSince1970: TimeInterval(fields[2]) ?? 0))
        }
    }
    /// Saves staged and unstaged edits under `message` and cleans the checkout; staging is
    /// recorded so Apply and Pop can restore it.
    public func stash(message: String, includeUntracked: Bool, root: String) async throws {
        var arguments = ["stash", "push"]
        if includeUntracked { arguments.append("--include-untracked") }
        let output = try await text(arguments + ["--message=\(message)"], root: root, timeout: 120)
        if output.contains("No local changes to save") { throw ProcessFailure.exited("There are no changes to stash.") }
    }
    /// Restores the stash with its staging. Pop drops it only after a clean apply; Git keeps it on conflict.
    public func applyStash(_ stash: GitStash, pop: Bool, root: String) async throws {
        try await verify(stash, root: root)
        _ = try await text(["stash", pop ? "pop" : "apply", "--index", "--quiet", stash.reference], root: root, timeout: 120)
    }
    public func dropStash(_ stash: GitStash, root: String) async throws {
        try await verify(stash, root: root)
        _ = try await text(["stash", "drop", "--quiet", stash.reference], root: root)
    }
    private func verify(_ stash: GitStash, root: String) async throws {
        let current = try? await text(["rev-parse", "--verify", "--quiet", stash.reference], root: root)
        guard current == stash.commit else { throw ProcessFailure.exited("The stash list changed. Review the stashes again before continuing.") }
    }
}
