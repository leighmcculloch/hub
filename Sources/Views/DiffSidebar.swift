import AppKit
import SwiftUI

/// The right-hand sidebar. For local shells it shows the git worktree diff of
/// the terminal's current directory. For VM-backed (SSH) tabs it lists the git
/// repos in the VM's home directory, lets you pick one, browse its changed
/// files, and view the diff of each — all over SSH.
struct DiffSidebar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            if let session = workspace.selectedSession {
                if let destination = session.sshDestination {
                    RemoteDiffView(destination: destination).id(destination)
                } else {
                    LocalDiffView(session: session).id(session.id)
                }
            } else {
                DiffPlaceholder(
                    text: "No terminal selected",
                    icon: "sidebar.right",
                    detail: "Pick a session on the left to inspect its worktree.")
            }
        }
        // Width is owned by ContentView so the divider can resize it.
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
    }
}

// MARK: - Remote (VM) diff

@MainActor
private final class RemoteDiffModel: ObservableObject {
    let destination: String

    @Published var repos: [String] = []
    /// nil == all repos.
    @Published var selectedRepo: String?
    /// Changed files, their line counts and the repo's log — one poll's answer
    /// per repo, kept together because one remote command produces all three.
    @Published var statusByRepo: [String: GitRepoStatus] = [:]
    @Published var selection: DiffTarget?
    @Published var diffText: String = ""
    @Published var loadingRepos = false
    @Published var loadingDiff = false
    /// Non-nil when the VM couldn't be reached, so "no repos" isn't shown for
    /// what is really a connection failure.
    @Published var connectionError: String?

    /// How long to wait between polls; widens while the VM is unreachable.
    private var backoff = PollBackoff()
    /// Guards against overlapping refreshes when SSH is slower than the poll.
    private var isRefreshing = false

    /// Nonisolated so `RemoteDiffView.init` can construct it; only assigns a
    /// stored property.
    nonisolated init(destination: String) {
        self.destination = destination
    }

    var visibleRepos: [String] {
        if let selectedRepo { return repos.contains(selectedRepo) ? [selectedRepo] : [] }
        return repos
    }

    /// Load once with a spinner, then keep polling until the view goes away
    /// (the enclosing `.task` cancels this).
    func pollLoop() async {
        await refresh(showSpinner: true)
        while !Task.isCancelled {
            try? await Task.sleep(for: backoff.delay)
            if Task.isCancelled { break }
            await refresh(showSpinner: false)
        }
    }

    /// Re-read repos, their changed files, and the open diff. Published values
    /// are only reassigned when they actually differ, so unchanged polls don't
    /// churn the view (and don't disturb scrolling or selection).
    func refresh(showSpinner: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if showSpinner { loadingRepos = true }

        let discovered: [String]
        do {
            discovered = try await RemoteGit.listRepos(destination: destination)
            backoff.recordSuccess()
            if connectionError != nil { connectionError = nil }
        } catch {
            // Keep the last known repos on screen rather than blanking the
            // sidebar on a transient blip; the banner explains the staleness.
            backoff.recordFailure()
            let message = (error as? RemoteGitError)?.message ?? error.localizedDescription
            if connectionError != message { connectionError = message }
            if showSpinner { loadingRepos = false }
            return
        }
        if discovered != repos { repos = discovered }
        if let selected = selectedRepo, !discovered.contains(selected) { selectedRepo = nil }

        var map: [String: GitRepoStatus] = [:]
        for repo in visibleRepos {
            map[repo] = await RemoteGit.status(destination: destination, repo: repo)
        }
        if map != statusByRepo { statusByRepo = map }

        // Keep the open diff live too. A commit range is re-read as well: its
        // base can be a branch ref, which moves when the default branch does.
        if let selection {
            let text = await diff(for: selection)
            if text != diffText { diffText = text }
        }

        if showSpinner { loadingRepos = false }
    }

    func select(_ target: DiffTarget) async {
        selection = target
        loadingDiff = true
        diffText = await diff(for: target)
        loadingDiff = false
    }

    private func diff(for target: DiffTarget) async -> String {
        switch target {
        case let .file(repo, path):
            return await RemoteGit.fileDiff(destination: destination, repo: repo, file: path)
        case let .commits(repo, _, exclusiveBase):
            guard let newest = target.newestSha else { return "" }
            return await RemoteGit.rangeDiff(
                destination: destination, repo: repo, from: exclusiveBase, to: newest)
        }
    }

    func changes(in repo: String) -> [GitFileChange] { statusByRepo[repo]?.changes ?? [] }
    func log(in repo: String) -> GitLog { statusByRepo[repo]?.log ?? GitLog() }

    var totalChanges: Int { statusByRepo.values.reduce(0) { $0 + $1.changes.count } }
    var totalCommits: Int { statusByRepo.values.reduce(0) { $0 + $1.log.commits.count } }

    /// The logs the pane shows, in the same order as the file list above.
    var visibleLogs: [RepoLog] {
        visibleRepos.map { RepoLog(repo: $0, log: log(in: $0)) }
    }
}

private struct RemoteDiffView: View {
    @StateObject private var model: RemoteDiffModel
    /// Shared with the local view (and persisted) so the pane splits stay where
    /// the user put them.
    @AppStorage("diffFileListHeight") private var fileListHeight: Double = 200
    @AppStorage("diffLogHeight") private var logHeight: Double = 160

    init(destination: String) {
        _model = StateObject(wrappedValue: RemoteDiffModel(destination: destination))
    }

    var body: some View {
        // The geometry is only used to keep the draggable splits from squeezing
        // the diff out of short windows.
        GeometryReader { geometry in
            let listRange = splitRange(in: geometry.size.height)
            let listHeight = clamped(fileListHeight, in: listRange)
            let logRange = splitRange(in: geometry.size.height, reserving: listHeight)

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                repoPicker
                if let error = model.connectionError {
                    ConnectionErrorBanner(destination: model.destination, message: error)
                }
                Divider()
                if model.repos.isEmpty {
                    noReposState
                } else {
                    fileList.frame(height: listHeight)
                    SplitHandle(height: $fileListHeight, range: listRange, label: "file list")
                    logPane.frame(height: clamped(logHeight, in: logRange))
                    SplitHandle(height: $logHeight, range: logRange, label: "commit log")
                    diffPane
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        // Loads once, then auto-refreshes until the view goes away.
        .task { await model.pollLoop() }
        .onChange(of: model.selectedRepo) {
            Task { await model.refresh(showSpinner: true) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Worktree Diff").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 4) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(model.destination)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if model.loadingRepos { ProgressView().controlSize(.small) }
            Button(action: { Task { await model.refresh(showSpinner: true) } }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(model.loadingRepos)
            .help("Refresh from \(model.destination)")
            .accessibilityLabel("Refresh worktree diff")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var repoPicker: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(.secondary).font(.caption)
            Picker("Repository", selection: $model.selectedRepo) {
                Text("All repos").tag(String?.none)
                ForEach(model.repos, id: \.self) { repo in
                    Text(RepoLabel.short(repo)).tag(String?.some(repo))
                }
            }
            .labelsHidden()
            .help("Choose which repo in the VM's home directory to inspect")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            FileListCaption(count: model.totalChanges)
            if model.totalChanges == 0 {
                DiffPlaceholder(
                    text: model.loadingRepos ? "Checking for changes…" : "No changes",
                    icon: "checkmark.circle",
                    detail: model.selectedRepo.map { "\(RepoLabel.short($0)) is clean." }
                        ?? "Every repo here is clean.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.visibleRepos, id: \.self) { repo in
                            let changes = model.changes(in: repo)
                            if !changes.isEmpty {
                                // With one repo picked the header would just
                                // repeat the picker, so it's only shown in
                                // "All repos".
                                if model.selectedRepo == nil {
                                    RepoHeader(repo: repo, count: changes.count, noun: "changed")
                                }
                                ForEach(changes) { change in
                                    Button {
                                        Task {
                                            await model.select(.file(repo: repo, path: change.path))
                                        }
                                    } label: {
                                        FileRow(
                                            change: change,
                                            isSelected: model.selection?
                                                .selects(repo: repo, path: change.path) ?? false,
                                            stat: model.statusByRepo[repo]?.stats[change.path]
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private var logPane: some View {
        LogPane(
            logs: model.visibleLogs,
            showsRepoHeaders: model.selectedRepo == nil,
            totalCommits: model.totalCommits,
            isLoading: model.loadingRepos,
            selection: model.selection,
            select: { target in Task { await model.select(target) } })
    }

    private var noReposState: some View {
        DiffPlaceholder(
            text: model.loadingRepos ? "Looking for repos…" : "No git repos in ~",
            icon: "folder",
            detail: model.loadingRepos ? nil : "The VM may still be cloning — refresh to look again.")
    }

    @ViewBuilder
    private var diffPane: some View {
        if model.loadingDiff {
            DiffPlaceholder(text: "Loading diff…", busy: true)
        } else if let selection = model.selection {
            if model.diffText.isEmpty {
                DiffPlaceholder(
                    text: "No line changes",
                    icon: "doc",
                    detail: selection.newestSha == nil
                        ? "This file is new, binary, or unchanged against HEAD."
                        : "These commits touch no text.")
            } else {
                DiffTextView(diff: model.diffText, subject: subject(of: selection))
            }
        } else {
            DiffPlaceholder(
                text: "Nothing selected",
                icon: "doc.plaintext",
                detail: "Pick a changed file or a commit above to read its diff.")
        }
    }

    private func subject(of selection: DiffTarget) -> DiffSubject {
        switch selection {
        case let .file(_, path):
            return .file(path)
        case let .commits(repo, _, _):
            return .commits(selection.label(in: model.log(in: repo)))
        }
    }
}

// MARK: - Local diff

private struct LocalDiffView: View {
    @ObservedObject var session: TerminalSession
    @State private var state: GitWorktreeState?
    @State private var isLoading = false
    @State private var reloadToken = 0
    /// The whole-repo diff is one document, so picking a file scrolls to it
    /// rather than re-fetching anything.
    @State private var focusedPath: String?
    /// Non-nil while a run of commits is being read instead of the worktree.
    @State private var commitSelection: DiffTarget?
    @State private var commitDiff = ""
    @State private var loadingCommitDiff = false
    @AppStorage("diffFileListHeight") private var fileListHeight: Double = 200
    @AppStorage("diffLogHeight") private var logHeight: Double = 160

    var body: some View {
        GeometryReader { geometry in
            let listRange = splitRange(in: geometry.size.height)
            let listHeight = clamped(fileListHeight, in: listRange)
            let logRange = splitRange(in: geometry.size.height, reserving: listHeight)

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()

                if let state {
                    changeList(state).frame(height: listHeight)
                    SplitHandle(height: $fileListHeight, range: listRange, label: "file list")
                    logPane(state).frame(height: clamped(logHeight, in: logRange))
                    SplitHandle(height: $logHeight, range: logRange, label: "commit log")
                    diffPane(state)
                } else if isLoading {
                    DiffPlaceholder(text: "Loading…", busy: true)
                } else if session.workingDirectory == nil {
                    DiffPlaceholder(
                        text: "Waiting for a directory…",
                        icon: "clock",
                        detail: "The diff follows the shell's current directory.")
                } else {
                    DiffPlaceholder(
                        text: "Not a git repository",
                        icon: "folder",
                        detail: "cd into a repo to see its worktree diff.")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        // Reloads when the cwd changes or on manual refresh, then keeps polling
        // so edits show up without interaction.
        .task(id: "\(session.workingDirectory?.path ?? "")#\(reloadToken)") {
            await reload(showSpinner: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                await reload(showSpinner: false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Worktree Diff").font(.system(size: 12, weight: .semibold))
                if let state {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text("\(state.repoRoot.lastPathComponent) · \(state.branch ?? "detached")")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 0)
            if isLoading { ProgressView().controlSize(.small) }
            Button(action: { reloadToken += 1 }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .help("Refresh the worktree diff")
            .accessibilityLabel("Refresh worktree diff")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func changeList(_ state: GitWorktreeState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FileListCaption(count: state.changes.count)
            if state.isClean {
                DiffPlaceholder(
                    text: "No changes",
                    icon: "checkmark.circle",
                    detail: "The working tree matches HEAD.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(state.changes) { change in
                            Button {
                                focusedPath = change.path
                                // The worktree diff and a commit diff share the
                                // pane, so picking a file takes it back.
                                commitSelection = nil
                            } label: {
                                FileRow(
                                    change: change,
                                    isSelected: commitSelection == nil && focusedPath == change.path)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func logPane(_ state: GitWorktreeState) -> some View {
        LogPane(
            logs: [RepoLog(repo: state.repoRoot.lastPathComponent, log: state.log)],
            showsRepoHeaders: false,
            totalCommits: state.log.commits.count,
            isLoading: isLoading,
            selection: commitSelection,
            select: { target in selectCommits(target, in: state) })
    }

    @ViewBuilder
    private func diffPane(_ state: GitWorktreeState) -> some View {
        if let commitSelection {
            if loadingCommitDiff {
                DiffPlaceholder(text: "Loading diff…", busy: true)
            } else if commitDiff.isEmpty {
                DiffPlaceholder(
                    text: "No line changes",
                    icon: "doc",
                    detail: "These commits touch no text.")
            } else {
                DiffTextView(
                    diff: commitDiff,
                    subject: .commits(commitSelection.label(in: state.log)))
            }
        } else if state.isClean {
            DiffPlaceholder(
                text: "No changes",
                icon: "checkmark.circle",
                detail: "Pick a commit below to read what it changed.")
        } else {
            DiffTextView(diff: state.diff, subject: .worktree, scrollTarget: focusedPath)
        }
    }

    private func selectCommits(_ target: DiffTarget, in state: GitWorktreeState) {
        guard case let .commits(_, _, exclusiveBase) = target,
              let newest = target.newestSha else { return }
        commitSelection = target
        loadingCommitDiff = true
        let root = state.repoRoot
        Task {
            commitDiff = await Task.detached(priority: .userInitiated) {
                GitWorktree.rangeDiff(in: root, from: exclusiveBase, to: newest)
            }.value
            loadingCommitDiff = false
        }
    }

    private func reload(showSpinner: Bool) async {
        guard let directory = session.workingDirectory else {
            state = nil
            return
        }
        if showSpinner { isLoading = true }
        let computed = await Task.detached(priority: .userInitiated) {
            GitWorktree.state(for: directory)
        }.value
        // Moving to another repo invalidates a commit picked in the old one.
        if computed?.repoRoot != state?.repoRoot {
            commitSelection = nil
            commitDiff = ""
        }
        // Only reassign when changed, so quiet polls don't churn the view.
        if computed != state { state = computed }
        if showSpinner { isLoading = false }
    }
}

/// Bounds for one of the draggable splits above the diff: never let a pane take
/// so much room that the diff disappears in a short window. `reserving` is the
/// height already given to the panes above this one.
private func splitRange(in available: CGFloat, reserving used: CGFloat = 0) -> ClosedRange<Double> {
    70...max(70, Double(available) - Double(used) - 200)
}

private func clamped(_ stored: Double, in range: ClosedRange<Double>) -> CGFloat {
    CGFloat(min(max(stored, range.lowerBound), range.upperBound))
}

// MARK: - Commit log

/// One repo's log, as the log pane lists it.
struct RepoLog: Identifiable {
    var id: String { repo }
    let repo: String
    let log: GitLog
}

/// The commit log pane, below the file list: for each repo shown, the commits it
/// has that its default branch doesn't — the branch's own work, newest first.
///
/// Clicking a commit shows its diff; shift-clicking a second one selects the run
/// between them and shows their combined diff. The "all commits" row at the top
/// of each repo is that range taken to its limit, the whole branch against the
/// default branch.
private struct LogPane: View {
    let logs: [RepoLog]
    /// Off when the picker above has already narrowed to one repo, matching how
    /// the file list decides.
    let showsRepoHeaders: Bool
    let totalCommits: Int
    let isLoading: Bool
    let selection: DiffTarget?
    let select: (DiffTarget) -> Void

    /// Where a shift-click measures from: the last commit picked without one.
    @State private var anchor: CommitAnchor?

    /// The default branch to name in the caption. Only meaningful with one repo
    /// on screen — across several they can differ, and each repo's own row says
    /// what it is measured against anyway.
    private var singleBase: String {
        logs.count == 1 ? logs[0].log.base : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LogCaption(count: totalCommits, base: singleBase)
            if totalCommits == 0 {
                DiffPlaceholder(
                    text: isLoading ? "Reading the log…" : "No commits ahead",
                    icon: "clock.arrow.circlepath",
                    detail: isLoading ? nil : emptyDetail)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(logs) { entry in
                            if !entry.log.commits.isEmpty {
                                repoSection(entry)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private var emptyDetail: String {
        singleBase.isEmpty
            ? "Only commits a branch has beyond its default branch are listed."
            : "This is \(singleBase), or matches it — commits already on it aren't listed."
    }

    @ViewBuilder
    private func repoSection(_ entry: RepoLog) -> some View {
        if showsRepoHeaders {
            RepoHeader(repo: entry.repo, count: entry.log.commits.count, noun: "commits")
        }
        Button {
            select(.allCommits(repo: entry.repo, log: entry.log))
        } label: {
            AllCommitsRow(
                count: entry.log.commits.count,
                base: entry.log.base,
                isSelected: selection?.selectsAll(repo: entry.repo, log: entry.log) ?? false)
        }
        .buttonStyle(.plain)

        ForEach(Array(entry.log.commits.enumerated()), id: \.element.id) { index, commit in
            Button {
                pick(entry, index: index)
            } label: {
                CommitRow(
                    commit: commit,
                    isSelected: selection?.selects(repo: entry.repo, sha: commit.sha) ?? false)
            }
            .buttonStyle(.plain)
        }
    }

    /// Extends the selection when shift is held, otherwise starts a new one.
    ///
    /// The modifiers are read from the current event rather than taken from the
    /// gesture: a plain `Button` doesn't report them, and every other way of
    /// getting them here costs the button's own keyboard and accessibility
    /// behaviour.
    private func pick(_ entry: RepoLog, index: Int) {
        let extending = NSEvent.modifierFlags.contains(.shift) && anchor?.repo == entry.repo
        if !extending { anchor = CommitAnchor(repo: entry.repo, index: index) }
        select(.commits(
            repo: entry.repo,
            log: entry.log,
            picking: index,
            extendingFrom: extending ? anchor?.index : nil))
    }
}

private struct CommitAnchor: Equatable {
    let repo: String
    let index: Int
}

/// The row that selects a repo's whole branch at once.
private struct AllCommitsRow: View {
    let count: Int
    let base: String
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 15)
            Text(count == 1 ? "All 1 commit" : "All \(count) commits")
                .font(.system(size: 11, weight: .medium))
            if !base.isEmpty {
                Text("vs \(base)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(rowFill(isSelected, isHovering)))
        .overlay(alignment: .leading) { SelectionBar(isSelected: isSelected) }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(base.isEmpty ? "Diff every commit listed" : "Diff this branch against \(base)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// One commit: its hash, subject, and when it landed.
private struct CommitRow: View {
    let commit: GitCommit
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(commit.sha)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(commit.subject)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(commit.relativeDate)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(rowFill(isSelected, isHovering)))
        .overlay(alignment: .leading) { SelectionBar(isSelected: isSelected) }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help("\(commit.sha) · \(commit.subject) · \(commit.author) · \(commit.relativeDate)\n"
              + "Shift-click another commit to diff the range")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(commit.subject), by \(commit.author), \(commit.relativeDate), \(commit.sha)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Caption above the log, naming what the list stops at.
private struct LogCaption: View {
    let count: Int
    let base: String

    var body: some View {
        HStack {
            Text(count == 1 ? "1 commit" : "\(count) commits")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            if !base.isEmpty {
                Text("ahead of \(base)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

// MARK: - File list

/// A changed-file row that keeps a sense of the file structure: the directory is
/// dimmed and the filename emphasized.
/// Shown when the VM can't be reached. Without this a connection failure is
/// indistinguishable from an empty home directory.
private struct ConnectionErrorBanner: View {
    let destination: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Can't reach \(destination)")
                    .font(.system(size: 11, weight: .semibold))
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cannot reach \(destination). \(message)")
    }
}

/// Compact `+N −M` for a changed file, so the list conveys size as well as
/// which files changed.
private struct LineStatLabel: View {
    let stat: GitLineStat

    var body: some View {
        HStack(spacing: 3) {
            if stat.isBinary {
                Text("bin")
                    .foregroundStyle(.tertiary)
            } else {
                if let added = stat.added, added > 0 {
                    Text("+\(added)").foregroundStyle(.green)
                }
                if let removed = stat.removed, removed > 0 {
                    Text("−\(removed)").foregroundStyle(.red)
                }
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if stat.isBinary { return "binary file" }
        return "\(stat.added ?? 0) added, \(stat.removed ?? 0) removed"
    }
}

private struct FileRow: View {
    let change: GitFileChange
    let isSelected: Bool
    /// Line counts, absent for untracked files (they aren't in `git diff`).
    var stat: GitLineStat? = nil

    @State private var isHovering = false

    private var status: FileStatus { FileStatus(code: change.status) }

    var body: some View {
        HStack(spacing: 6) {
            FileStatusBadge(status: status)
            Text(structuredPath(change.path))
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if let stat {
                LineStatLabel(stat: stat)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(rowFill(isSelected, isHovering)))
        .overlay(alignment: .leading) { SelectionBar(isSelected: isSelected) }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help("\(status.label) · \(status.stagingNote) · \(change.path)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.label), \(status.stagingNote), \(change.path)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private func rowFill(_ isSelected: Bool, _ isHovering: Bool) -> Color {
    if isSelected { return Color.accentColor.opacity(0.22) }
    return isHovering ? Color.primary.opacity(0.07) : .clear
}

/// A leading bar that keeps a selected row readable even where the accent tint
/// is subtle (light mode, graphite accent).
private struct SelectionBar: View {
    let isSelected: Bool

    var body: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor)
                .frame(width: 2)
                .padding(.vertical, 3)
        }
    }
}

/// Names a repo above its rows, in both the file list and the log.
private struct RepoHeader: View {
    let repo: String
    let count: Int
    /// What the count means here — "changed" or "commits".
    let noun: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: RepoLabel.isWorktree(repo) ? "arrow.triangle.branch" : "folder.fill")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Text(RepoLabel.short(repo))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            CountBadge(count: count)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(RepoLabel.spoken(repo)), \(count) \(noun)")
        .help(repo)
    }
}

/// A readable reading of git's two-character porcelain code, so the list can say
/// "Modified" instead of " M" and colour the badge accordingly.
private struct FileStatus {
    let letter: String
    let label: String
    let color: Color
    /// True when the change is in the index (`git add`-ed); drawn as a filled
    /// badge, unstaged as an outlined one.
    let isStaged: Bool

    init(code: String) {
        let index = code.first ?? " "
        let worktree = code.dropFirst().first ?? " "
        isStaged = index != " " && index != "?"

        if code == "??" {
            letter = "?"; label = "Untracked"; color = .green
        } else if code == "!!" {
            letter = "!"; label = "Ignored"; color = .secondary
        } else if index == "U" || worktree == "U" || code == "AA" || code == "DD" {
            letter = "!"; label = "Conflicted"; color = .red
        } else if index == "R" || worktree == "R" {
            letter = "R"; label = "Renamed"; color = .purple
        } else if index == "C" || worktree == "C" {
            letter = "C"; label = "Copied"; color = .blue
        } else if index == "A" || worktree == "A" {
            letter = "A"; label = "Added"; color = .green
        } else if index == "D" || worktree == "D" {
            letter = "D"; label = "Deleted"; color = .red
        } else if index == "M" || worktree == "M" {
            letter = "M"; label = "Modified"; color = .orange
        } else {
            letter = String(index == " " ? worktree : index)
            label = "Changed"
            color = .orange
        }
    }

    var stagingNote: String { isStaged ? "staged" : "unstaged" }
}

private struct FileStatusBadge: View {
    let status: FileStatus

    var body: some View {
        Text(status.letter)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(status.isStaged ? Color.white : status.color)
            .frame(width: 15, height: 15)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(status.isStaged ? status.color : status.color.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(status.color.opacity(status.isStaged ? 0 : 0.5), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}

/// Caption above a file list, so the size of the change set is visible without
/// counting rows.
private struct FileListCaption: View {
    let count: Int

    var body: some View {
        HStack {
            Text(count == 1 ? "1 changed file" : "\(count) changed files")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

private struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

/// Path with the directory dimmed so the filename stays scannable in a narrow
/// column.
private func structuredPath(_ path: String) -> AttributedString {
    let components = path.split(separator: "/").map(String.init)
    guard let file = components.last else { return AttributedString(path) }
    let dir = components.dropLast().joined(separator: "/")
    var result = AttributedString()
    if !dir.isEmpty {
        var d = AttributedString(dir + "/")
        d.foregroundColor = .secondary
        result += d
    }
    result += AttributedString(file)
    return result
}

// MARK: - Diff rendering

/// One rendered line of a unified diff.
/// A scrollable unified-diff view with a line-number gutter, tinted +/- rows and
/// styled hunk headers. The sidebar is narrow, so lines soft-wrap under the
/// gutter rather than forcing a horizontal scroll to read the ends of lines.
/// What a rendered diff covers. It decides the pane header, and whether the
/// per-file header rows inside the diff are worth drawing.
private enum DiffSubject: Equatable {
    /// One file's worktree diff. Its per-file header would only repeat the
    /// pane's own title.
    case file(String)
    /// A run of commits, already labelled for display.
    case commits(String)
    /// Everything uncommitted in the worktree.
    case worktree

    /// Off for a single file, whose one header row would only repeat the pane
    /// title; on for a commit range, which spans several files.
    var showsFileHeaders: Bool {
        if case .file = self { return false }
        return true
    }
}

private struct DiffTextView: View {
    let diff: String
    var subject: DiffSubject = .worktree
    /// Path to scroll into view, for multi-file (whole-repo) diffs.
    var scrollTarget: String?

    @State private var parsed = ParsedDiff()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(parsed.rows) { row in
                            DiffRowView(row: row, gutterWidth: parsed.gutterWidth).id(row.id)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target,
                          let row = parsed.rows.first(where: { $0.kind == .file && $0.text == target })
                    else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(row.id, anchor: .top) }
                }
            }
        }
        // Re-parse only when the text really changes: a poll that returns the
        // same diff must not disturb the rendered rows or the scroll position.
        .onAppear { reparse() }
        .onChange(of: diff) { reparse() }
    }

    private var paneHeader: some View {
        HStack(spacing: 6) {
            switch subject {
            case let .file(path):
                Text(structuredPath(path))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(path)
            case let .commits(label):
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(label)
            case .worktree:
                Text("All changes").font(.system(size: 11, weight: .semibold))
            }
            Spacer(minLength: 0)
            DiffStatLabel(additions: parsed.additions, deletions: parsed.deletions)
            Button(action: copyDiff) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy this diff")
            .accessibilityLabel("Copy diff")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func reparse() {
        parsed = ParsedDiff.parse(diff, includeFileHeaders: subject.showsFileHeaders)
    }

    /// Rows are separate `Text`s, so a drag-selection can't span them — this
    /// button is how the whole diff gets out of the app.
    private func copyDiff() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diff, forType: .string)
    }
}

/// "+12 −3" — the shape of a change at a glance.
private struct DiffStatLabel: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 5) {
            if additions > 0 { Text("+\(additions)").foregroundStyle(.green) }
            if deletions > 0 { Text("−\(deletions)").foregroundStyle(.red) }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(additions) added, \(deletions) removed")
    }
}

private struct DiffRowView: View {
    let row: DiffRow
    let gutterWidth: CGFloat

    var body: some View {
        switch row.kind {
        case .file:
            HStack(spacing: 5) {
                Image(systemName: "doc.plaintext").font(.system(size: 9)).foregroundStyle(.secondary)
                Text(structuredPath(row.text))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.07))

        case .hunk:
            HStack(spacing: 6) {
                Text(row.text)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.12))

        case .meta:
            Text(row.text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)

        case .addition, .deletion, .context:
            codeRow
        }
    }

    private var codeRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(row.number.map { String($0) } ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 5)
            Text(marker)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(markerColor)
                .frame(width: 9, alignment: .leading)
            // Wrapped continuations line up under the code column, which is why
            // the marker and number live in their own fixed-width columns.
            Text(row.text.isEmpty ? " " : row.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(row.kind == .context ? Color.primary.opacity(0.75) : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
        }
        .padding(.vertical, 1)
        .background(tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var marker: String {
        switch row.kind {
        case .addition: return "+"
        case .deletion: return "-"
        default: return " "
        }
    }

    private var markerColor: Color {
        switch row.kind {
        case .addition: return .green
        case .deletion: return .red
        default: return .secondary
        }
    }

    /// Tint carries the add/remove meaning so the code itself can stay in the
    /// normal text colour and remain legible.
    private var tint: Color {
        switch row.kind {
        case .addition: return Color.green.opacity(0.13)
        case .deletion: return Color.red.opacity(0.13)
        default: return .clear
        }
    }

    private var accessibilityText: String {
        let kind: String
        switch row.kind {
        case .addition: kind = "Added"
        case .deletion: kind = "Removed"
        default: kind = "Unchanged"
        }
        let number = row.number.map { " line \($0)" } ?? ""
        return "\(kind)\(number): \(row.text)"
    }
}

// MARK: - Shared

/// A thin divider that drags to rebalance the panes above and below it — the
/// horizontal sibling of `ResizeHandle`, which sizes the sidebars.
private struct SplitHandle: View {
    @Binding var height: Double
    let range: ClosedRange<Double>
    /// Names the pane above it, for the tooltip.
    let label: String

    @State private var heightAtDragStart: Double?

    var body: some View {
        Rectangle()
            // Nearly transparent, but tall enough to be an easy drag target.
            .fill(Color.primary.opacity(0.001))
            .frame(height: 7)
            .overlay(Divider())
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = heightAtDragStart ?? height
                        if heightAtDragStart == nil { heightAtDragStart = height }
                        let proposed = base + Double(value.translation.height)
                        height = min(max(proposed, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in heightAtDragStart = nil }
            )
            .help("Drag to resize the \(label)")
            .accessibilityHidden(true)
    }
}

private struct DiffPlaceholder: View {
    let text: String
    var icon: String?
    var detail: String?
    /// Shows a spinner in place of the icon while something is in flight.
    var busy = false

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
            }
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
