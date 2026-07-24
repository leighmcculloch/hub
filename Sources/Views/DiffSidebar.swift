import SwiftUI

/// The right-hand sidebar. Shows the git worktree diff for the directory the
/// selected terminal is currently in, refreshing automatically as the shell's
/// working directory changes (and on demand).
struct DiffSidebar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            if let session = workspace.selectedSession {
                DiffContent(session: session)
            } else {
                DiffPlaceholder(text: "No terminal selected")
            }
        }
        .frame(width: 380)
        .background(.thinMaterial)
    }
}

private struct DiffContent: View {
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
                    diffText(state)
                }
            } else if isLoading {
                DiffPlaceholder(text: "Loading…")
            } else {
                DiffPlaceholder(text: session.workingDirectory == nil
                    ? "Waiting for a directory…"
                    : "Not a git repository")
            }
        }
        // Recompute whenever the directory changes or the user asks to refresh.
        .task(id: "\(session.workingDirectory?.path ?? "")#\(reloadToken)") {
            await reload()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Worktree Diff")
                    .font(.system(size: 12, weight: .semibold))
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
                    HStack(spacing: 6) {
                        Text(change.status.replacingOccurrences(of: " ", with: "·"))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(change.isUntracked ? .green : .orange)
                            .frame(width: 22, alignment: .leading)
                        Text(change.path)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 150)
    }

    private func diffText(_ state: GitWorktreeState) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(attributedDiff(state.diff))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }

    /// Colorize the unified diff: additions green, deletions red, hunk headers
    /// accented.
    private func attributedDiff(_ diff: String) -> AttributedString {
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

    private func reload() async {
        guard let directory = session.workingDirectory else {
            state = nil
            return
        }
        isLoading = true
        // Run git off the main thread.
        let computed = await Task.detached(priority: .userInitiated) {
            GitWorktree.state(for: directory)
        }.value
        state = computed
        isLoading = false
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
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
