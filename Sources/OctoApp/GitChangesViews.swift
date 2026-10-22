import AppKit
import SwiftUI
import OctoCore
import OctoGit

/// The Changes tab's Git row: the branch over its upstream state, then Pull (when behind), Push,
/// Create PR and more actions. Pulling, pushing and publishing happen only from these explicit buttons.
struct GitHeader: View {
    @ObservedObject var git: GitWorkflow
    let review: ReviewModel
    let target: GitWorkflow.Target
    let branch: String
    let files: [ChangedFile]
    let loading: Bool
    let refresh: () -> Void
    @Environment(\.octoTheme) private var theme

    private var status: UpstreamStatus? { git.status }
    private var unstaged: [ChangedFile] { files.filter(\.hasWorking) }
    private var staged: [ChangedFile] { files.filter(\.hasStaged) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title over subtitle, as in the titlebar: the branch, then its upstream state.
            HStack(spacing: 7) {
                GitBranchIcon(size: 14).foregroundStyle(theme.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(branch.isEmpty ? "No branch" : branch).font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Group {
                        if let notice = git.notice { Text("\(Image(systemName: "checkmark.circle.fill")) \(notice)").foregroundStyle(theme.green) }
                        else { Text(statusText).foregroundStyle(theme.secondary) }
                    }.font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                }.help(branch)
                Spacer(minLength: 6)
                ProgressView().controlSize(.small)
                    .opacity(loading || git.activity != nil ? 1 : 0).accessibilityHidden(!loading && git.activity == nil)
                    .help(git.activity ?? "Refreshing")
                if let status, status.behind > 0, !status.publishes {
                    Button(action: pull) { Label("Pull \(status.behind)", systemImage: "arrow.down").labelStyle(.titleAndIcon) }
                        .buttonStyle(CapsuleButtonStyle()).disabled(git.activity != nil)
                        .help("Fast-forward to \(status.upstream ?? "the upstream") (\(Self.commits(status.behind)))")
                }
                // Without a remote there is nowhere to publish, so neither action is offered.
                if status?.pushRemote != nil {
                    Button(action: push) { Label(pushTitle, systemImage: "arrow.up").labelStyle(.titleAndIcon) }
                        .buttonStyle(CapsuleButtonStyle()).disabled(status?.canPush != true).help(pushHelp)
                    Button { git.sheet = .pullRequest } label: {
                        Label(git.pullRequest(for: target).map { "PR #\($0.number)" } ?? "Create PR", systemImage: "arrow.triangle.pull").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(CapsuleButtonStyle()).disabled(status?.branch == nil || status?.hasCommits != true)
                    .help(git.pullRequest(for: target) == nil ? "Create a GitHub pull request for this branch" : "View this branch's pull request")
                }
                moreMenu
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(CapsuleToolbarButtonStyle()).help("Refresh changes (⇧⌘R)").accessibilityLabel("Refresh changes")
            }
            if let problem = git.pushProblem {
                GitBanner(problem: problem, retry: status?.canPush == true ? push : nil) { git.pushProblem = nil }
            }
            if let problem = git.problem, git.sheet == nil {
                GitBanner(problem: problem, retry: nil) { git.problem = nil }
            }
        }
        .sheet(item: $git.sheet) { sheet in
            switch sheet {
            case .stashes: StashesSheet(git: git, review: review, target: target, canStash: !files.isEmpty)
            case .newStash: NewStashSheet(git: git, review: review, target: target, branch: branch, hasUntracked: files.contains(where: \.isUntracked))
            case .pullRequest: PullRequestSheet(git: git, review: review, target: target)
            }
        }
        .alert(discardTitle, isPresented: Binding(get: { git.discardRequest != nil }, set: { if !$0 { git.discardRequest = nil } }),
               presenting: git.discardRequest) { files in
            Button("Discard Changes", role: .destructive) { Task { await git.discard(files, in: target, review: review) } }
            Button("Cancel", role: .cancel) {}
        } message: { files in Text(Self.discardMessage(files)) }
    }
    private var moreMenu: some View {
        Menu {
            Button("Stage All") { Task { await git.stage(unstaged, in: target, review: review) } }.disabled(unstaged.isEmpty)
            Button("Unstage All") { Task { await git.unstage(staged, in: target, review: review) } }.disabled(staged.isEmpty)
            Divider()
            Button("Stash Changes…") { git.sheet = .newStash }.disabled(files.isEmpty)
            Button(git.stashes.isEmpty ? "Stashes…" : "Stashes (\(git.stashes.count))…") { git.sheet = .stashes }
            Button("Pull") { pull() }.disabled(status?.upstream == nil || status?.upstreamGone == true)
            Button("Fetch") { Task { await git.fetch(in: target, review: review) } }.disabled(status?.remotes.isEmpty != false)
            Divider()
            Button("Discard All Unstaged Changes…", role: .destructive) { git.discardRequest = unstaged }.disabled(unstaged.isEmpty)
        } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).frame(width: 28, height: 28).contentShape(Capsule()) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(theme.secondary).hoverFeedback()
            .help("More Git actions").accessibilityLabel("More Git actions")
    }
    private func push() { Task { await git.push(in: target, review: review) } }
    private func pull() { Task { await git.pull(in: target, review: review) } }
    private var pushTitle: String {
        guard let status else { return "Push" }
        if status.publishes && status.ahead == 0 { return "Publish" }
        return status.ahead > 0 ? "Push \(status.ahead)" : "Push"
    }
    private var pushHelp: String {
        guard let status, let branch = status.branch else { return "Check out a branch to push" }
        guard status.hasCommits else { return "Commit before pushing" }
        guard let remote = status.pushRemote else { return status.remotes.isEmpty ? "This repository has no remote" : "Several remotes and no origin: push from the terminal" }
        if status.publishes { return "Publish \(branch) to \(remote) and track it" }
        return status.ahead > 0 ? "Push \(Self.commits(status.ahead)) to \(status.upstream ?? remote)" : "Up to date with \(status.upstream ?? remote)"
    }
    private var statusText: String {
        guard let status else { return " " }
        guard status.branch != nil else { return "Detached HEAD · check out a branch to push" }
        guard status.hasCommits else { return "No commits yet" }
        if let upstream = status.upstream, status.upstreamGone { return "\(upstream) no longer exists · Push publishes it again" }
        guard let upstream = status.upstream else {
            guard let remote = status.pushRemote else { return status.remotes.isEmpty ? "No remote" : "Not published" }
            return "Not on \(remote)" + (status.ahead > 0 ? " · \(Self.commits(status.ahead)) to publish" : "")
        }
        var parts = [upstream]
        if status.ahead > 0 { parts.append("\(Self.commits(status.ahead)) to push") }
        if status.behind > 0 { parts.append("\(status.behind) behind") }
        if status.ahead == 0 && status.behind == 0 { parts.append("Up to date") }
        return parts.joined(separator: " · ")
    }
    static func commits(_ count: Int) -> String { count == 1 ? "1 commit" : "\(count) commits" }
    private var discardTitle: String {
        guard let files = git.discardRequest else { return "" }
        return files.count == 1 ? "Discard changes to \(GitWorkflow.name(files[0]))?" : "Discard all unstaged changes?"
    }
    static func discardMessage(_ files: [ChangedFile]) -> String {
        let untracked = files.filter(\.isUntracked)
        var text = "Staged changes are kept. "
        if files.count == 1 {
            text += untracked.isEmpty ? "This restores the file to its staged or committed version." : "This deletes the untracked file from the checkout."
        } else {
            let tracked = files.count - untracked.count
            text += tracked == 0 ? "This deletes" : "This restores \(CommitComposer.files(tracked)) to their staged or committed versions"
            text += untracked.isEmpty ? ":" : (tracked == 0 ? " \(untracked.count) untracked " : " and deletes \(untracked.count) untracked ") + (untracked.count == 1 ? "file:" : "files:")
            text += "\n\n" + files.prefix(8).map(\.path).joined(separator: "\n") + (files.count > 8 ? "\n…and \(files.count - 8) more" : "")
        }
        return text + "\n\nGit can't recover these edits."
    }
}

/// An actionable failure. A hint leads, with Git's own output available beneath it.
struct GitBanner: View {
    let problem: GitProblem
    var retry: (() -> Void)?
    let dismiss: () -> Void
    @State private var expanded = false
    @Environment(\.octoTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.red).font(.system(size: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(problem.title).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if let hint = problem.hint { Text(hint).font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true) }
                    else if let detail = problem.detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(theme.secondary).lineLimit(5).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 4)
                if let retry { Button("Retry", action: retry).buttonStyle(CapsuleButtonStyle()) }
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(theme.secondary).help("Dismiss").accessibilityLabel("Dismiss")
            }
            if problem.hint != nil, let detail = problem.detail, !detail.isEmpty {
                DisclosureGroup("Git output", isExpanded: $expanded) {
                    ScrollView {
                        Text(detail).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 110)
                }.font(.system(size: 11)).padding(.leading, 19)
            }
        }
        .padding(9).background(theme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A Staged or Unstaged heading with its group action.
struct ChangesGroupHeader: View {
    let title: String
    let count: Int
    let actionTitle: String
    let action: () -> Void
    @Environment(\.octoTheme) private var theme
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(theme.secondary)
            Text("\(count)").font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(theme.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1).background(theme.field, in: Capsule())
            Spacer(minLength: 0)
            Button(actionTitle, action: action).buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                .foregroundStyle(count == 0 ? theme.secondary : theme.accent).disabled(count == 0).hoverFeedback()
        }
        .padding(.horizontal, 8).frame(height: 26)
        .accessibilityElement(children: .contain).accessibilityLabel("\(title), \(count) files")
    }
}

/// Commits only what is staged. After a commit, the next explicit step (Push or Create PR) appears.
struct CommitComposer: View {
    @ObservedObject var git: GitWorkflow
    let review: ReviewModel
    let target: GitWorkflow.Target
    let stagedCount: Int
    let unstagedCount: Int
    @State private var message = ""
    @Environment(\.octoTheme) private var theme
    var body: some View {
        // A clean checkout shows nothing until there is a commit to follow up.
        let last = stagedCount == 0 ? git.lastCommit : nil
        VStack(alignment: .leading, spacing: 7) {
            if last != nil || stagedCount + unstagedCount > 0 {
                Rectangle().fill(theme.hairline).frame(height: 0.5).padding(.horizontal, -12).padding(.bottom, 3)
                if let last { committed(last) }
                else if stagedCount > 0 { composer }
                else {
                    // Collapsed until there is something to commit; a typed draft is kept.
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle").foregroundStyle(theme.secondary)
                        Text("Stage files or hunks to commit them").foregroundStyle(theme.secondary)
                        Spacer(minLength: 6)
                        if !message.isEmpty { Text("Draft kept").foregroundStyle(theme.secondary) }
                    }.font(.system(size: 11.5)).lineLimit(1).frame(minHeight: 20)
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, last != nil || stagedCount + unstagedCount > 0 ? 12 : 0)
        .onAppear { message = git.drafts[target.root] ?? "" }
        .onChange(of: target) { _, target in message = git.drafts[target.root] ?? "" }
        .onChange(of: message) { _, text in git.drafts[target.root] = text.isEmpty ? nil : text }
    }
    private var canCommit: Bool { stagedCount > 0 && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && git.activity == nil }
    @ViewBuilder private var composer: some View {
        Text("Commit staged changes").font(.system(size: 12, weight: .semibold))
        ZStack(alignment: .topLeading) {
            CommitMessageEditor(text: $message, textColor: theme.textColor)
            if message.isEmpty {
                Text("Describe the staged changes…").font(.system(size: 12.5)).foregroundStyle(theme.secondary)
                    .padding(.leading, 5).padding(.top, 2).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .frame(height: 54).padding(6).background(theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        HStack(spacing: 8) {
            Text(summary).font(.system(size: 11)).foregroundStyle(theme.secondary).lineLimit(1)
            Spacer(minLength: 6)
            Button(action: commit) { Label("Commit", systemImage: "checkmark") }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small).foregroundStyle(theme.onAccent)
                .disabled(!canCommit).help(stagedCount == 0 ? "Stage a file or hunk to commit it" : "Commit the staged changes only")
        }
    }
    private var summary: String {
        return "\(Self.files(stagedCount)) staged" + (unstagedCount > 0 ? " · \(unstagedCount) unstaged not included" : "")
    }
    static func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }
    private func commit() {
        guard canCommit else { return }
        let text = message
        Task {
            await git.commit(message: text, in: target, review: review)
            if git.drafts[target.root] == nil, message == text { message = "" }
        }
    }
    private func committed(_ last: CommitSummary) -> some View {
        let request = git.pullRequest(for: target), status = git.status
        let unpushed = status?.canPush == true
        return HStack(alignment: .center, spacing: 9) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(theme.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(request != nil ? "Pull request open" : unpushed ? "Committed locally" : "Branch pushed").font(.system(size: 12.5, weight: .semibold))
                Text("\(last.hash) · \(last.subject)").font(.system(size: 11)).foregroundStyle(theme.secondary).lineLimit(1).truncationMode(.tail)
                Text(unstagedCount > 0 ? "\(Self.files(unstagedCount)) unstaged, kept on disk." : "All staged changes committed.")
                    .font(.system(size: 11)).foregroundStyle(theme.secondary)
            }
            Spacer(minLength: 6)
            Group {
                if unpushed {
                    Button { Task { await git.push(in: target, review: review) } } label: {
                        Label(status.map { $0.publishes && $0.ahead == 0 ? "Publish" : "Push \(GitHeader.commits($0.ahead))" } ?? "Push", systemImage: "arrow.up")
                    }.disabled(git.activity != nil)
                } else {
                    Button { git.sheet = .pullRequest } label: {
                        Label(request.map { "View PR #\($0.number)" } ?? "Create PR", systemImage: "arrow.triangle.pull")
                    }.disabled(status?.pushRemote == nil)
                }
            }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small).foregroundStyle(theme.onAccent)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A multi-line native editor in which Tab and Shift-Tab move focus, so keyboard users are never
/// trapped in it as they are in SwiftUI's TextEditor. Return inserts a line for the message body.
struct CommitMessageEditor: NSViewRepresentable {
    @Binding var text: String
    var textColor: NSColor
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        let view = CommitMessageTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        view.isRichText = false; view.importsGraphics = false; view.allowsUndo = true; view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isContinuousSpellCheckingEnabled = true
        view.font = .systemFont(ofSize: 12.5); view.textContainerInset = NSSize(width: 0, height: 2)
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Commit message")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        view.textColor = textColor; view.insertionPointColor = textColor
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { text.wrappedValue = view.string }
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)) { textView.window?.selectNextKeyView(nil); return true }
            if selector == #selector(NSResponder.insertBacktab(_:)) { textView.window?.selectPreviousKeyView(nil); return true }
            return false
        }
    }
}
final class CommitMessageTextView: NSTextView {}

// MARK: Sheets

struct StashesSheet: View {
    @ObservedObject var git: GitWorkflow
    let review: ReviewModel
    let target: GitWorkflow.Target
    let canStash: Bool
    @State private var dropping: GitStash?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.octoTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stashes").font(.headline)
                    Text("Saved changes for this checkout").font(.system(size: 11.5)).foregroundStyle(theme.secondary)
                }
                Spacer()
                Button("Stash Changes…") { git.sheet = .newStash }.disabled(!canStash)
            }
            if let problem = git.problem { GitBanner(problem: problem, retry: nil) { git.problem = nil } }
            if git.stashes.isEmpty {
                ContentUnavailableView("No stashes", systemImage: "tray", description: Text("Use Stash Changes to save unfinished edits."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) { ForEach(git.stashes) { row($0) } }
                }
            }
            HStack {
                Text("Apply keeps the stash. Pop removes it after a clean apply.").font(.system(size: 11)).foregroundStyle(theme.secondary)
                Spacer()
                ProgressView().controlSize(.small).opacity(git.activity == nil ? 0 : 1)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 480, height: 400)
        .alert("Drop “\(dropping?.message ?? "")”?", isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }), presenting: dropping) { stash in
            Button("Drop Stash", role: .destructive) { Task { await git.drop(stash, in: target, review: review) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("The saved copy will be removed. Changes already applied to the checkout stay.") }
    }
    private func row(_ stash: GitStash) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stash.message).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
            Text("\(stash.reference) · \(stash.branch ?? "detached HEAD") · \(stash.date.formatted(.relative(presentation: .named)))")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.secondary).lineLimit(1)
            HStack(spacing: 6) {
                Button("Apply") { Task { await git.apply(stash, pop: false, in: target, review: review) } }
                    .help("Restore these changes and their staging, and keep the stash")
                Button("Pop") { Task { await git.apply(stash, pop: true, in: target, review: review) } }
                    .help("Restore these changes and their staging, then remove the stash")
                Spacer()
                Button("Drop…", role: .destructive) { dropping = stash }
            }.controlSize(.small).disabled(git.activity != nil)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct NewStashSheet: View {
    @ObservedObject var git: GitWorkflow
    let review: ReviewModel
    let target: GitWorkflow.Target
    let branch: String
    let hasUntracked: Bool
    @State private var name = ""
    @State private var includeUntracked = true
    @Environment(\.octoTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stash Changes").font(.headline)
                Text("Save your edits under a name and clean the checkout.").font(.system(size: 11.5)).foregroundStyle(theme.secondary)
            }
            TextField("Stash name", text: $name).textFieldStyle(.roundedBorder)
            Toggle("Include untracked files", isOn: $includeUntracked).disabled(!hasUntracked)
            Text("Staged and unstaged edits to tracked files are saved together with their staging. Untracked files stay on disk unless included.")
                .font(.system(size: 11)).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem = git.problem { GitBanner(problem: problem, retry: nil) { git.problem = nil } }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { git.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Stash Changes", action: stash).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || git.activity != nil)
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { if name.isEmpty { name = branch.isEmpty ? "WIP" : "WIP on \(branch)" } }
    }
    private func stash() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), untracked = includeUntracked && hasUntracked
        Task { if await git.stash(name: name, includeUntracked: untracked, in: target, review: review) { git.sheet = nil } }
    }
}

/// Creates a pull request with the GitHub CLI after the branch is pushed. Unpushed commits must be
/// pushed explicitly first; this sheet never pushes as part of Create.
struct PullRequestSheet: View {
    @ObservedObject var git: GitWorkflow
    let review: ReviewModel
    let target: GitWorkflow.Target
    @State private var loading = true
    @State private var existing: PullRequest?
    @State private var bases: [String] = []
    @State private var base = ""
    @State private var title = ""
    @State private var bodyText = ""
    @State private var draft = true
    @State private var working = false
    @State private var failure: String?
    @Environment(\.octoTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(existing.map { "Pull Request #\($0.number)" } ?? "Create Pull Request").font(.headline)
                Text("GitHub · \(git.status?.branch ?? "")").font(.system(size: 11.5)).foregroundStyle(theme.secondary)
            }
            if loading { ProgressView().frame(maxWidth: .infinity, minHeight: 160) }
            else if let existing { result(existing) }
            else if !PullRequests.isAvailable {
                notice("Install the GitHub CLI (gh) and sign in with “gh auth login” to create pull requests from Octo.", systemImage: "exclamationmark.triangle")
            } else { form }
            if let failure {
                ScrollView { Text(failure).font(.system(size: 11)).foregroundStyle(theme.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 90)
            }
            HStack {
                Spacer()
                if existing != nil || loading || !PullRequests.isAvailable {
                    Button("Done") { git.sheet = nil }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { git.sheet = nil }.keyboardShortcut(.cancelAction)
                    if git.status?.canPush == true {
                        Button { push() } label: { Label(git.status?.publishes == true && git.status?.ahead == 0 ? "Publish Branch" : "Push Branch", systemImage: "arrow.up") }
                            .keyboardShortcut(.defaultAction).disabled(working || git.activity != nil)
                    } else {
                        Button(draft ? "Create Draft PR" : "Create PR", action: create).keyboardShortcut(.defaultAction)
                            .disabled(working || title.trimmingCharacters(in: .whitespaces).isEmpty || base.isEmpty)
                    }
                }
            }
        }
        .padding(20).frame(width: 520)
        .task { await load() }
    }
    @ViewBuilder private var form: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.pull").foregroundStyle(theme.secondary)
            if bases.isEmpty {
                TextField("Base branch", text: $base).textFieldStyle(.roundedBorder).frame(width: 160)
            } else {
                Picker("Base", selection: $base) { ForEach(bases, id: \.self) { Text($0).tag($0) } }.frame(width: 200)
            }
            Text("←").foregroundStyle(theme.secondary)
            Text(git.status?.branch ?? "").font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
        }
        TextField("Title", text: $title).textFieldStyle(.roundedBorder)
        VStack(alignment: .leading, spacing: 4) {
            Text("Description").font(.system(size: 11.5, weight: .medium)).foregroundStyle(theme.secondary)
            TextEditor(text: $bodyText).font(.system(size: 12.5)).scrollContentBackground(.hidden).frame(height: 120)
                .padding(6).background(theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("Description")
        }
        Toggle("Create as draft", isOn: $draft)
        if let status = git.status, status.canPush {
            notice(status.publishes && status.ahead == 0 ? "This branch isn't on \(status.pushRemote ?? "the remote") yet. Publish it before creating the pull request."
                   : "\(GitHeader.commits(status.ahead)) haven't been pushed. Push the branch before creating the pull request.", systemImage: "arrow.up.circle")
        } else if let status = git.status {
            notice("Opens from \(status.upstream ?? status.branch ?? "this branch") with its pushed commits. Uncommitted edits are excluded.", systemImage: "info.circle")
        }
    }
    private func notice(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage).font(.system(size: 11.5)).foregroundStyle(theme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    private func result(_ request: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.title).font(.system(size: 14, weight: .semibold))
            Text("\(request.isDraft ? "Draft" : "Open") · \(git.status?.branch ?? "") → \(request.baseRefName)").font(.system(size: 12)).foregroundStyle(theme.secondary)
            Button { if let url = URL(string: request.url) { NSWorkspace.shared.open(url) } } label: { Label("Open on GitHub", systemImage: "safari") }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func load() async {
        defer { loading = false }
        guard PullRequests.isAvailable else { return }
        do { existing = try await git.lookUpPullRequest(in: target) }
        catch { failure = "Couldn't look up pull requests: \(error.localizedDescription)" }
        guard existing == nil else { return }
        let found = await git.baseBranches(in: target)
        bases = found.branches
        base = found.defaultBranch.flatMap { bases.contains($0) ? $0 : nil } ?? bases.first(where: { $0 == "main" || $0 == "master" }) ?? bases.first ?? ""
        if !base.isEmpty {
            let draft = await git.pullRequestDraft(base: base, in: target)
            if title.isEmpty { title = draft.title }
            if bodyText.isEmpty { bodyText = draft.body }
        }
    }
    private func push() {
        working = true
        Task {
            await git.push(in: target, review: review)
            working = false
            failure = git.pushProblem.map { [$0.title, $0.hint, $0.detail].compactMap { $0 }.joined(separator: "\n") }
        }
    }
    private func create() {
        working = true; failure = nil
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do { existing = try await git.createPullRequest(title: title, body: bodyText, base: base, draft: draft, in: target) }
            catch { failure = "Couldn't create the pull request. Your branch and commits are unchanged.\n\n" + error.localizedDescription }
            working = false
        }
    }
}
