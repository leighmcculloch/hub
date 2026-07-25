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
                DiffPlaceholder(text: "No terminal selected")
            }
        }
        .frame(width: 380)
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
    @Published var changesByRepo: [String: [GitFileChange]] = [:]
    @Published var selectedKey: String?
    @Published var diffText: String = ""
    @Published var loadingRepos = false
    @Published var loadingDiff = false

    init(destination: String) {
        self.destination = destination
    }

    var visibleRepos: [String] {
        if let selectedRepo { return repos.contains(selectedRepo) ? [selectedRepo] : [] }
        return repos
    }

    func key(repo: String, path: String) -> String { repo + "\u{1}" + path }

    func reload() async {
        loadingRepos = true
        repos = await RemoteGit.listRepos(destination: destination)
        if let selected = selectedRepo, !repos.contains(selected) { selectedRepo = nil }

        var map: [String: [GitFileChange]] = [:]
        for repo in visibleRepos {
            map[repo] = await RemoteGit.changes(destination: destination, repo: repo)
        }
        changesByRepo = map
        loadingRepos = false
    }

    func selectFile(repo: String, path: String) async {
        selectedKey = key(repo: repo, path: path)
        loadingDiff = true
        diffText = await RemoteGit.fileDiff(destination: destination, repo: repo, file: path)
        loadingDiff = false
    }

    var totalChanges: Int { changesByRepo.values.reduce(0) { $0 + $1.count } }
}

private struct RemoteDiffView: View {
    @StateObject private var model: RemoteDiffModel

    init(destination: String) {
        _model = StateObject(wrappedValue: RemoteDiffModel(destination: destination))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            repoPicker
            Divider()
            fileList
            Divider()
            diffPane
        }
        .task { await model.reload() }
        .onChange(of: model.selectedRepo) { _ in
            Task { await model.reload() }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Worktree Diff").font(.system(size: 12, weight: .semibold))
                Text(model.destination).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: { Task { await model.reload() } }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(model.loadingRepos)
        }
        .padding(10)
    }

    private var repoPicker: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(.secondary).font(.caption)
            Picker("Repository", selection: $model.selectedRepo) {
                Text("All repos").tag(String?.none)
                ForEach(model.repos, id: \.self) { repo in
                    Text(repo).tag(String?.some(repo))
                }
            }
            .labelsHidden()
            if model.loadingRepos { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var fileList: some View {
        if model.repos.isEmpty {
            DiffPlaceholder(text: model.loadingRepos ? "Loading…" : "No git repos in ~ (still cloning?) — Refresh")
                .frame(height: 120)
        } else if model.totalChanges == 0 {
            DiffPlaceholder(text: model.loadingRepos ? "Loading…" : "No changes")
                .frame(height: 120)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.visibleRepos, id: \.self) { repo in
                        let changes = model.changesByRepo[repo] ?? []
                        if !changes.isEmpty {
                            if model.selectedRepo == nil {
                                Text(repo)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 6)
                            }
                            ForEach(changes) { change in
                                FileRow(
                                    change: change,
                                    isSelected: model.selectedKey == model.key(repo: repo, path: change.path)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Task { await model.selectFile(repo: repo, path: change.path) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .frame(minHeight: 120, maxHeight: 260)
        }
    }

    @ViewBuilder
    private var diffPane: some View {
        if model.loadingDiff {
            DiffPlaceholder(text: "Loading diff…")
        } else if model.selectedKey == nil {
            DiffPlaceholder(text: "Select a file to see its diff")
        } else if model.diffText.isEmpty {
            DiffPlaceholder(text: "No line changes (new or binary file)")
        } else {
            DiffTextView(diff: model.diffText)
        }
    }
}

/// A changed-file row that keeps a sense of the file structure: the directory is
/// dimmed and the filename emphasized.
private struct FileRow: View {
    let change: GitFileChange
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(change.status.replacingOccurrences(of: " ", with: "·"))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(change.isUntracked ? .green : .orange)
                .frame(width: 22, alignment: .leading)
            Text(structuredPath)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : .clear)
        )
    }

    private var structuredPath: AttributedString {
        let components = change.path.split(separator: "/").map(String.init)
        guard let file = components.last else { return AttributedString(change.path) }
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
}

// MARK: - Local diff

private struct LocalDiffView: View {
    @ObservedObject var session: TerminalSession
    @State private var state: GitWorktreeState?
    @State private var isLoading = false
    @State private var reloadToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let state {
                if state.isClean {
                    DiffPlaceholder(text: "Working tree clean")
                } else {
                    changeList(state)
                    Divider()
                    DiffTextView(diff: state.diff)
                }
            } else if isLoading {
                DiffPlaceholder(text: "Loading…")
            } else {
                DiffPlaceholder(text: session.workingDirectory == nil
                    ? "Waiting for a directory…"
                    : "Not a git repository")
            }
        }
        .task(id: "\(session.workingDirectory?.path ?? "")#\(reloadToken)") {
            await reload()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Worktree Diff").font(.system(size: 12, weight: .semibold))
                if let state {
                    Text("\(state.repoRoot.lastPathComponent) · \(state.branch ?? "detached")")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: { reloadToken += 1 }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
        .padding(10)
    }

    private func changeList(_ state: GitWorktreeState) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(state.changes) { change in
                    FileRow(change: change, isSelected: false)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 150)
    }

    private func reload() async {
        guard let directory = session.workingDirectory else {
            state = nil
            return
        }
        isLoading = true
        let computed = await Task.detached(priority: .userInitiated) {
            GitWorktree.state(for: directory)
        }.value
        state = computed
        isLoading = false
    }
}

// MARK: - Shared

/// A scrollable, colorized unified-diff view.
private struct DiffTextView: View {
    let diff: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(Self.colorize(diff))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: .infinity)
    }

    /// Additions green, deletions red, hunk headers accented.
    static func colorize(_ diff: String) -> AttributedString {
        var result = AttributedString()
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            var attributed = AttributedString(String(line) + "\n")
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                attributed.foregroundColor = .green
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                attributed.foregroundColor = .red
            } else if line.hasPrefix("@@") {
                attributed.foregroundColor = .cyan
            } else if line.hasPrefix("diff ") || line.hasPrefix("+++") || line.hasPrefix("---") {
                attributed.foregroundColor = .secondary
            }
            result += attributed
        }
        return result
    }
}

private struct DiffPlaceholder: View {
    let text: String
    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
