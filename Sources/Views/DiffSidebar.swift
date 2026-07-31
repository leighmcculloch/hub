import AppKit
import SwiftUI

/// The right-hand sidebar's diff tab, organised as scope → files → diff:
/// pick *what* to read (a repo's working tree or a run of its commits),
/// narrow to one of that scope's files if wanted, and read the diff below.
///
/// For local shells the scopes come from the git worktree of the terminal's
/// current directory. For VM-backed (SSH) tabs they come from the git repos in
/// the VM's home directory — pick one (or all), and everything is read over
/// SSH.
struct DiffSidebar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            if let session = workspace.selectedSession {
                if let destination = session.sshDestination {
                    RemoteDiffView(
                        destination: destination,
                        transport: session.provider.transport(forDestination: destination))
                        .id(destination)
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
    private let transport: RemoteTransport

    @Published var repos: [String] = []
    /// nil == all repos.
    @Published var selectedRepo: String?
    /// Changed files, their line counts and the repo's log — one poll's answer
    /// per repo, kept together because one remote command produces all three.
    @Published var statusByRepo: [String: GitRepoStatus] = [:]
    /// The selected scope. Nil only while several repos are visible and the
    /// user hasn't picked yet — one visible repo defaults to its worktree.
    @Published var scope: DiffTarget?
    /// A file picked within the scope; nil reads the scope's whole diff.
    @Published var selectedFile: String?
    /// The open commit scope's file list, fetched on selection. A worktree
    /// scope's files are read straight out of `statusByRepo` instead.
    @Published var commitFiles = GitScopeFiles()
    @Published var loadingFiles = false
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

    /// Nonisolated so `RemoteDiffView.init` can construct it; only assigns
    /// stored properties. `transport` is Sendable so it can be held off the main
    /// actor for the polling git calls.
    nonisolated init(destination: String, transport: RemoteTransport) {
        self.destination = destination
        self.transport = transport
    }

    var visibleRepos: [String] {
        if let selectedRepo { return repos.contains(selectedRepo) ? [selectedRepo] : [] }
        return repos
    }

    /// The open scope's file list, whichever kind of scope it is.
    var scopeFiles: GitScopeFiles {
        switch scope {
        case let .worktree(repo)?:
            let status = statusByRepo[repo]
            return GitScopeFiles(changes: status?.changes ?? [], stats: status?.stats ?? [:])
        case .commits?:
            return commitFiles
        case nil:
            return GitScopeFiles()
        }
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

    /// Re-read repos, their changed files, and the open scope. Published values
    /// are only reassigned when they actually differ, so unchanged polls don't
    /// churn the view (and don't disturb scrolling or selection).
    func refresh(showSpinner: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if showSpinner { loadingRepos = true }

        let discovered: [String]
        do {
            discovered = try await RemoteGit.listRepos(transport: transport)
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
            map[repo] = await RemoteGit.status(transport: transport, repo: repo)
        }
        let changed = map != statusByRepo
        if changed { statusByRepo = map }

        // Default to the worktree when there's exactly one repo to mean by it.
        var needsReload = changed
        if scope == nil, visibleRepos.count == 1, let only = visibleRepos.first {
            scope = .worktree(repo: only)
            needsReload = true
        }
        if validateScope() { needsReload = true }

        // Keep the open scope live. Re-reading is gated on the poll having
        // changed something: a commit range's contents are fixed for as long
        // as its commits are, and a moved base ref shows up as a changed log.
        if needsReload {
            await reloadScopeContent()
            validateSelectedFile()
        }

        if showSpinner { loadingRepos = false }
    }

    func selectScope(_ target: DiffTarget) async {
        // Re-clicking the selected scope drops a file pick, back to the
        // scope's whole diff.
        if target == scope, selectedFile != nil {
            selectedFile = nil
            await reloadDiff()
            return
        }
        guard target != scope else { return }
        scope = target
        selectedFile = nil
        await reloadScopeContent()
    }

    func selectFile(_ path: String) async {
        selectedFile = path
        await reloadDiff()
    }

    /// Re-read the open scope's files (commit scopes fetch theirs) and diff.
    private func reloadScopeContent() async {
        guard let scope else { diffText = ""; return }
        if let range = scope.commitRange {
            loadingFiles = true
            let files = await RemoteGit.scopeFiles(
                transport: transport, repo: scope.repo, from: range.from, to: range.to)
            if self.scope == scope { commitFiles = files }
            loadingFiles = false
        }
        await reloadDiff()
    }

    private func reloadDiff() async {
        guard let scope else { diffText = ""; return }
        let file = selectedFile
        loadingDiff = true
        let text = await diff(for: scope, file: file)
        // A pick made while this was in flight owns the pane now.
        if self.scope == scope, self.selectedFile == file { diffText = text }
        loadingDiff = false
    }

    private func diff(for scope: DiffTarget, file: String?) async -> String {
        switch scope {
        case let .worktree(repo):
            if let file {
                return await RemoteGit.fileDiff(transport: transport, repo: repo, file: file)
            }
            return await RemoteGit.repoDiff(transport: transport, repo: repo)
        case .commits:
            guard let range = scope.commitRange else { return "" }
            if let file {
                return await RemoteGit.rangeFileDiff(
                    transport: transport, repo: scope.repo,
                    from: range.from, to: range.to, file: file)
            }
            return await RemoteGit.rangeDiff(
                transport: transport, repo: scope.repo, from: range.from, to: range.to)
        }
    }

    /// A scope can outlive what it points at: its repo disappears, or a rebase
    /// drops the selected commits from the log. Fall back to that repo's
    /// worktree, or to nothing. Returns true when it changed the selection.
    @discardableResult
    private func validateScope() -> Bool {
        guard let scope else {
            if selectedFile != nil { selectedFile = nil }
            return false
        }
        guard visibleRepos.contains(scope.repo) else {
            self.scope = nil
            selectedFile = nil
            return true
        }
        if case let .commits(_, shas, _) = scope {
            let shasInLog = Set(log(in: scope.repo).commits.map(\.sha))
            if !shas.allSatisfy(shasInLog.contains) {
                self.scope = .worktree(repo: scope.repo)
                selectedFile = nil
                return true
            }
        }
        return false
    }

    /// A picked file can vanish from its scope the same way the scope can.
    private func validateSelectedFile() {
        guard let selectedFile,
              !scopeFiles.changes.contains(where: { $0.path == selectedFile })
        else { return }
        self.selectedFile = nil
    }

    func changes(in repo: String) -> [GitFileChange] { statusByRepo[repo]?.changes ?? [] }
    func log(in repo: String) -> GitLog { statusByRepo[repo]?.log ?? GitLog() }

    var totalCommits: Int { statusByRepo.values.reduce(0) { $0 + $1.log.commits.count } }

    /// The scopes the pane lists, one entry per visible repo.
    var visibleScopes: [RepoScope] {
        visibleRepos.map {
            RepoScope(repo: $0, changeCount: changes(in: $0).count, log: log(in: $0))
        }
    }
}

private struct RemoteDiffView: View {
    @StateObject private var model: RemoteDiffModel
    /// Shared with the local view (and persisted) so the pane splits stay where
    /// the user put them.
    @AppStorage("diffFileListHeight") private var fileListHeight: Double = 200
    @AppStorage("diffLogHeight") private var scopeListHeight: Double = 160

    init(destination: String, transport: RemoteTransport) {
        _model = StateObject(wrappedValue: RemoteDiffModel(destination: destination, transport: transport))
    }

    var body: some View {
        // The geometry is only used to keep the draggable splits from squeezing
        // the diff out of short windows.
        GeometryReader { geometry in
            let scopeRange = splitRange(in: geometry.size.height)
            let scopeHeight = clamped(scopeListHeight, in: scopeRange)
            let fileRange = splitRange(in: geometry.size.height, reserving: scopeHeight)

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
                    scopePane.frame(height: scopeHeight)
                    SplitHandle(height: $scopeListHeight, range: scopeRange, label: "scope list")
                    filesPane.frame(height: clamped(fileListHeight, in: fileRange))
                    SplitHandle(height: $fileListHeight, range: fileRange, label: "file list")
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

    private var scopePane: some View {
        ScopeListPane(
            scopes: model.visibleScopes,
            showsRepoHeaders: model.selectedRepo == nil,
            totalCommits: model.totalCommits,
            selection: model.scope,
            select: { target in Task { await model.selectScope(target) } })
    }

    @ViewBuilder
    private var filesPane: some View {
        if let scope = model.scope {
            ScopeFilesPane(
                label: scope.label(in: model.log(in: scope.repo)),
                files: model.scopeFiles,
                isLoading: model.loadingFiles,
                selectedFile: model.selectedFile,
                showsStaging: scope.newestSha == nil,
                select: { path in Task { await model.selectFile(path) } })
        } else {
            DiffPlaceholder(
                text: "No scope selected",
                icon: "arrow.up.doc",
                detail: "Pick a working tree or commits above to list their files.")
        }
    }

    private var noReposState: some View {
        DiffPlaceholder(
            text: model.loadingRepos ? "Looking for repos…" : "No git repos in ~",
            icon: "folder",
            detail: model.loadingRepos ? nil : "The VM may still be cloning — refresh to look again.")
    }

    @ViewBuilder
    private var diffPane: some View {
        if let scope = model.scope {
            if model.loadingDiff, model.diffText.isEmpty {
                DiffPlaceholder(text: "Loading diff…", busy: true)
            } else if model.diffText.isEmpty {
                DiffPlaceholder(
                    text: "No line changes",
                    icon: "doc",
                    detail: emptyDiffDetail(for: scope))
            } else {
                DiffTextView(diff: model.diffText, subject: subject(of: scope))
            }
        } else {
            DiffPlaceholder(
                text: "Nothing selected",
                icon: "doc.plaintext",
                detail: "Pick a scope above to read its diff.")
        }
    }

    private func emptyDiffDetail(for scope: DiffTarget) -> String {
        let worktree = scope.newestSha == nil
        if model.selectedFile != nil {
            return worktree
                ? "This file is new, binary, or unchanged against HEAD."
                : "This file is unchanged across these commits."
        }
        return worktree ? "The worktree matches HEAD." : "These commits touch no text."
    }

    private func subject(of scope: DiffTarget) -> DiffSubject {
        if let file = model.selectedFile { return .file(file) }
        switch scope {
        case .worktree:
            return .worktree
        case .commits:
            return .commits(scope.label(in: model.log(in: scope.repo)))
        }
    }
}

// MARK: - Local diff

private struct LocalDiffView: View {
    @ObservedObject var session: TerminalSession
    @State private var state: GitWorktreeState?
    @State private var isLoading = false
    @State private var reloadToken = 0
    /// The selected scope; defaults to the worktree once a repo is known.
    @State private var scope: DiffTarget?
    /// A file picked within the scope; nil reads the scope's whole diff.
    @State private var selectedFile: String?
    /// A commit scope's file list and diff, fetched on selection. The worktree
    /// scope's arrive with the state — its whole-repo diff is one document, so
    /// picking one of its files scrolls to it rather than re-fetching anything.
    @State private var commitFiles = GitScopeFiles()
    @State private var commitDiff = ""
    @State private var loadingCommitFiles = false
    @State private var loadingCommitDiff = false
    @AppStorage("diffFileListHeight") private var fileListHeight: Double = 200
    @AppStorage("diffLogHeight") private var scopeListHeight: Double = 160

    var body: some View {
        GeometryReader { geometry in
            let scopeRange = splitRange(in: geometry.size.height)
            let scopeHeight = clamped(scopeListHeight, in: scopeRange)
            let fileRange = splitRange(in: geometry.size.height, reserving: scopeHeight)

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()

                if let state {
                    scopePane(state).frame(height: scopeHeight)
                    SplitHandle(height: $scopeListHeight, range: scopeRange, label: "scope list")
                    filesPane(state).frame(height: clamped(fileListHeight, in: fileRange))
                    SplitHandle(height: $fileListHeight, range: fileRange, label: "file list")
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

    private func scopePane(_ state: GitWorktreeState) -> some View {
        ScopeListPane(
            scopes: [RepoScope(
                repo: state.repoRoot.lastPathComponent,
                changeCount: state.changes.count,
                log: state.log)],
            showsRepoHeaders: false,
            totalCommits: state.log.commits.count,
            selection: scope,
            select: { target in selectScope(target, in: state) })
    }

    @ViewBuilder
    private func filesPane(_ state: GitWorktreeState) -> some View {
        if let scope {
            ScopeFilesPane(
                label: scope.label(in: state.log),
                files: scope.newestSha == nil
                    ? GitScopeFiles(changes: state.changes)
                    : commitFiles,
                isLoading: loadingCommitFiles,
                selectedFile: selectedFile,
                showsStaging: scope.newestSha == nil,
                select: { selectFile($0, in: state) })
        }
    }

    @ViewBuilder
    private func diffPane(_ state: GitWorktreeState) -> some View {
        if let scope, scope.newestSha != nil {
            // A commit scope reads its own document, fetched on selection.
            if loadingCommitDiff, commitDiff.isEmpty {
                DiffPlaceholder(text: "Loading diff…", busy: true)
            } else if commitDiff.isEmpty {
                DiffPlaceholder(
                    text: "No line changes",
                    icon: "doc",
                    detail: selectedFile != nil
                        ? "This file is unchanged across these commits."
                        : "These commits touch no text.")
            } else {
                DiffTextView(
                    diff: commitDiff,
                    subject: selectedFile.map(DiffSubject.file)
                        ?? .commits(scope.label(in: state.log)))
            }
        } else if state.isClean {
            DiffPlaceholder(
                text: "No changes",
                icon: "checkmark.circle",
                detail: "The working tree matches HEAD — pick commits above to read what landed.")
        } else {
            DiffTextView(diff: state.diff, subject: .worktree, scrollTarget: selectedFile)
        }
    }

    private func selectScope(_ target: DiffTarget, in state: GitWorktreeState) {
        // Re-clicking the selected scope drops a file pick, back to the
        // scope's whole diff.
        if target == scope {
            selectedFile = nil
            if target.newestSha != nil { loadCommitDiffWhole(target, in: state) }
            return
        }
        scope = target
        selectedFile = nil
        if target.newestSha != nil { loadCommitScope(target, in: state) }
    }

    private func selectFile(_ path: String, in state: GitWorktreeState) {
        selectedFile = path
        // A worktree file is scrolled to within the whole-repo diff; a commit
        // file needs its own read.
        if let scope, scope.newestSha != nil { loadCommitFileDiff(scope, file: path, in: state) }
    }

    /// Fetch a commit scope's file list and whole diff together.
    private func loadCommitScope(_ target: DiffTarget, in state: GitWorktreeState) {
        guard let range = target.commitRange else { return }
        loadingCommitFiles = true
        loadingCommitDiff = true
        let root = state.repoRoot
        Task {
            async let files = Task.detached(priority: .userInitiated) {
                GitWorktree.scopeFiles(in: root, from: range.from, to: range.to)
            }.value
            async let text = Task.detached(priority: .userInitiated) {
                GitWorktree.rangeDiff(in: root, from: range.from, to: range.to)
            }.value
            let newFiles = await files
            let newText = await text
            // Reset the spinners even when a pick made mid-flight has already
            // replaced this load — they belong to it either way.
            loadingCommitFiles = false
            loadingCommitDiff = false
            guard scope == target else { return }
            commitFiles = newFiles
            commitDiff = newText
        }
    }

    /// Re-fetch the scope's whole diff (a file pick was dropped).
    private func loadCommitDiffWhole(_ target: DiffTarget, in state: GitWorktreeState) {
        guard let range = target.commitRange else { return }
        let root = state.repoRoot
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                GitWorktree.rangeDiff(in: root, from: range.from, to: range.to)
            }.value
            guard scope == target, selectedFile == nil else { return }
            commitDiff = text
        }
    }

    private func loadCommitFileDiff(_ target: DiffTarget, file: String, in state: GitWorktreeState) {
        guard let range = target.commitRange else { return }
        loadingCommitDiff = true
        let root = state.repoRoot
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                GitWorktree.rangeFileDiff(in: root, from: range.from, to: range.to, path: file)
            }.value
            loadingCommitDiff = false
            guard scope == target, selectedFile == file else { return }
            commitDiff = text
        }
    }

    private func reload(showSpinner: Bool) async {
        guard let directory = session.workingDirectory else {
            state = nil
            scope = nil
            selectedFile = nil
            return
        }
        if showSpinner { isLoading = true }
        let computed = await Task.detached(priority: .userInitiated) {
            GitWorktree.state(for: directory)
        }.value

        let logChanged = computed?.log != state?.log
        // Moving to another repo invalidates a scope picked in the old one.
        if computed?.repoRoot != state?.repoRoot {
            scope = computed.map { .worktree(repo: $0.repoRoot.lastPathComponent) }
            selectedFile = nil
            commitDiff = ""
            commitFiles = GitScopeFiles()
        } else if let scope, case let .commits(_, shas, _) = scope,
                  let log = computed?.log,
                  !shas.allSatisfy({ sha in log.commits.contains(where: { $0.sha == sha }) }) {
            // A rebase dropped the picked commits; fall back to the worktree.
            self.scope = computed.map { .worktree(repo: $0.repoRoot.lastPathComponent) }
            selectedFile = nil
        }
        // Only reassign when changed, so quiet polls don't churn the view.
        if computed != state { state = computed }

        // A commit scope's contents are fixed for as long as its commits are;
        // only a changed log can move the base ref under it.
        if logChanged, let scope, scope.newestSha != nil, let computed {
            loadCommitScope(scope, in: computed)
        }
        // A worktree file that was committed or reverted is no longer a
        // sensible scroll target.
        if let selectedFile, scope?.newestSha == nil,
           let computed, !computed.changes.contains(where: { $0.path == selectedFile }) {
            self.selectedFile = nil
        }
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

// MARK: - Scope list

/// One repo's offer of scopes, as the scope pane lists it: the working tree
/// plus the commits the repo has that its default branch doesn't.
struct RepoScope: Identifiable {
    var id: String { repo }
    let repo: String
    /// Changed files in the worktree — the count the working-tree row shows.
    let changeCount: Int
    let log: GitLog
}

/// The top pane: what a diff can be read *of*. Each repo on screen offers its
/// working tree, an "all commits" row for the branch's whole work, and the
/// commits themselves — newest first, stopping at the default branch.
///
/// Clicking a scope shows its files below and its diff at the bottom;
/// shift-clicking a second commit selects the run between them. Clicking the
/// selected scope again drops a file pick, back to the scope's whole diff.
private struct ScopeListPane: View {
    let scopes: [RepoScope]
    /// Off when the picker above has already narrowed to one repo.
    let showsRepoHeaders: Bool
    let totalCommits: Int
    let selection: DiffTarget?
    let select: (DiffTarget) -> Void

    /// Where a shift-click measures from: the last commit picked without one.
    @State private var anchor: CommitAnchor?

    /// The default branch to name in the caption. Only meaningful with one repo
    /// on screen — across several they can differ, and each repo's own row says
    /// what it is measured against anyway.
    private var singleBase: String {
        scopes.count == 1 ? scopes[0].log.base : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScopeCaption(count: totalCommits, base: singleBase)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(scopes) { entry in
                        repoSection(entry)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder
    private func repoSection(_ entry: RepoScope) -> some View {
        if showsRepoHeaders {
            RepoHeader(repo: entry.repo, changeCount: entry.changeCount,
                       commitCount: entry.log.commits.count)
        }

        Button {
            select(.worktree(repo: entry.repo))
        } label: {
            WorkingTreeRow(
                count: entry.changeCount,
                isSelected: selection?.selectsWorktree(repo: entry.repo) ?? false)
        }
        .buttonStyle(.plain)

        if !entry.log.commits.isEmpty {
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
    }

    /// Extends the selection when shift is held, otherwise starts a new one.
    ///
    /// The modifiers are read from the current event rather than taken from the
    /// gesture: a plain `Button` doesn't report them, and every other way of
    /// getting them here costs the button's own keyboard and accessibility
    /// behaviour.
    private func pick(_ entry: RepoScope, index: Int) {
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

/// The row that selects a repo's uncommitted work.
private struct WorkingTreeRow: View {
    let count: Int
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 15)
            Text("Working tree")
                .font(.system(size: 11, weight: .medium))
            Text(count == 1 ? "1 change" : "\(count) changes")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(rowFill(isSelected, isHovering)))
        .overlay(alignment: .leading) { SelectionBar(isSelected: isSelected) }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(count == 0 ? "The working tree is clean" : "Diff the uncommitted changes")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
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

/// Caption above the scope list, naming what the commits stop at.
private struct ScopeCaption: View {
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

// MARK: - Scope files

/// The middle pane: the files of the selected scope. Picking one narrows the
/// diff below to it; the scope's whole diff shows while nothing is picked.
private struct ScopeFilesPane: View {
    /// The scope's own label — "Working tree" or a commit span.
    let label: String
    let files: GitScopeFiles
    let isLoading: Bool
    let selectedFile: String?
    /// Off for commit scopes, whose rows are committed content — the
    /// staged/unstaged note a worktree row carries would be wrong there.
    let showsStaging: Bool
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption
            if isLoading, files.changes.isEmpty {
                DiffPlaceholder(text: "Listing files…", busy: true)
            } else if files.changes.isEmpty {
                DiffPlaceholder(
                    text: "No changed files",
                    icon: "checkmark.circle",
                    detail: showsStaging
                        ? "The working tree matches HEAD."
                        : "These commits touch no files.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(files.changes) { change in
                            Button {
                                select(change.path)
                            } label: {
                                FileRow(
                                    change: change,
                                    isSelected: selectedFile == change.path,
                                    stat: files.stats[change.path],
                                    showsStaging: showsStaging)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private var caption: some View {
        HStack(spacing: 5) {
            Text("Files")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

// MARK: - Rows and badges

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

/// A changed-file row that keeps a sense of the file structure: the directory is
/// dimmed and the filename emphasized.
private struct FileRow: View {
    let change: GitFileChange
    let isSelected: Bool
    /// Line counts, absent for untracked files (they aren't in `git diff`).
    var stat: GitLineStat? = nil
    /// Off for commit scopes, where "staged/unstaged" is meaningless.
    var showsStaging = true

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
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var helpText: String {
        showsStaging
            ? "\(status.label) · \(status.stagingNote) · \(change.path)"
            : "\(status.label) · \(change.path)"
    }

    private var accessibilityText: String {
        showsStaging
            ? "\(status.label), \(status.stagingNote), \(change.path)"
            : "\(status.label), \(change.path)"
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

/// Names a repo above its scope rows, with a sense of how much is in it.
private struct RepoHeader: View {
    let repo: String
    let changeCount: Int
    let commitCount: Int

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
            Text("\(changeCount) changed · \(commitCount) commits")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(RepoLabel.spoken(repo)), \(changeCount) changed files, \(commitCount) commits")
        .help(repo)
    }
}

/// A readable reading of git's two-character porcelain code, so the list can say
/// "Modified" instead of " M" and colour the badge accordingly. Commit-scope
/// rows carry a single name-status letter in the index slot.
private struct FileStatus {
    let letter: String
    let label: String
    let color: Color
    /// True when the change is in the index (`git add`-ed) or committed; drawn
    /// as a filled badge, unstaged as an outlined one.
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

/// What a rendered diff covers. It decides the pane header, and whether the
/// per-file header rows inside the diff are worth drawing.
private enum DiffSubject: Equatable {
    /// One file's diff. Its per-file header would only repeat the pane's own
    /// title.
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

/// A scrollable unified-diff view with a line-number gutter, tinted +/- rows and
/// styled hunk headers. The sidebar is narrow, so lines soft-wrap under the
/// gutter rather than forcing a horizontal scroll to read the ends of lines.
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

/// One rendered line of a unified diff.
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
