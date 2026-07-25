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

/// Identifies the file whose diff is on screen.
struct SelectedFile: Equatable {
    let repo: String
    let path: String
}

@MainActor
private final class RemoteDiffModel: ObservableObject {
    let destination: String

    @Published var repos: [String] = []
    /// nil == all repos.
    @Published var selectedRepo: String?
    @Published var changesByRepo: [String: [GitFileChange]] = [:]
    @Published var selection: SelectedFile?
    @Published var diffText: String = ""
    @Published var loadingRepos = false
    @Published var loadingDiff = false

    /// How often the file list and open diff are refreshed from the VM.
    private static let pollInterval: Duration = .seconds(3)
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
            try? await Task.sleep(for: Self.pollInterval)
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

        let discovered = await RemoteGit.listRepos(destination: destination)
        if discovered != repos { repos = discovered }
        if let selected = selectedRepo, !discovered.contains(selected) { selectedRepo = nil }

        var map: [String: [GitFileChange]] = [:]
        for repo in visibleRepos {
            map[repo] = await RemoteGit.changes(destination: destination, repo: repo)
        }
        if map != changesByRepo { changesByRepo = map }

        // Keep the open diff live too.
        if let selection {
            let text = await RemoteGit.fileDiff(
                destination: destination, repo: selection.repo, file: selection.path)
            if text != diffText { diffText = text }
        }

        if showSpinner { loadingRepos = false }
    }

    func selectFile(repo: String, path: String) async {
        selection = SelectedFile(repo: repo, path: path)
        loadingDiff = true
        diffText = await RemoteGit.fileDiff(destination: destination, repo: repo, file: path)
        loadingDiff = false
    }

    var totalChanges: Int { changesByRepo.values.reduce(0) { $0 + $1.count } }
}

private struct RemoteDiffView: View {
    @StateObject private var model: RemoteDiffModel
    /// Shared with the local view (and persisted) so the file-list/diff split
    /// stays where the user put it.
    @AppStorage("diffFileListHeight") private var fileListHeight: Double = 200

    init(destination: String) {
        _model = StateObject(wrappedValue: RemoteDiffModel(destination: destination))
    }

    var body: some View {
        // The geometry is only used to keep the draggable split from squeezing
        // the diff out of short windows.
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                repoPicker
                Divider()
                if model.repos.isEmpty || model.totalChanges == 0 {
                    emptyState
                } else {
                    fileList
                        .frame(height: clampedListHeight(fileListHeight, in: geometry.size.height))
                    SplitHandle(height: $fileListHeight, range: splitRange(in: geometry.size.height))
                    diffPane
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        // Loads once, then auto-refreshes until the view goes away.
        .task { await model.pollLoop() }
        .onChange(of: model.selectedRepo) { _ in
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
                    Text(repo).tag(String?.some(repo))
                }
            }
            .labelsHidden()
            .help("Choose which repo in the VM's home directory to inspect")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            FileListCaption(count: model.totalChanges)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.visibleRepos, id: \.self) { repo in
                        let changes = model.changesByRepo[repo] ?? []
                        if !changes.isEmpty {
                            // With one repo picked the header would just repeat
                            // the picker, so it's only shown in "All repos".
                            if model.selectedRepo == nil {
                                repoHeader(repo: repo, count: changes.count)
                            }
                            ForEach(changes) { change in
                                Button {
                                    Task { await model.selectFile(repo: repo, path: change.path) }
                                } label: {
                                    FileRow(
                                        change: change,
                                        isSelected: model.selection == SelectedFile(repo: repo, path: change.path)
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

    private func repoHeader(repo: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
            Text(repo)
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
        .accessibilityLabel("\(repo), \(count) changed")
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.repos.isEmpty {
            DiffPlaceholder(
                text: model.loadingRepos ? "Looking for repos…" : "No git repos in ~",
                icon: "folder",
                detail: model.loadingRepos ? nil : "The VM may still be cloning — refresh to look again.")
        } else {
            DiffPlaceholder(
                text: model.loadingRepos ? "Checking for changes…" : "No changes",
                icon: "checkmark.circle",
                detail: model.selectedRepo.map { "\($0) is clean." } ?? "Every repo here is clean.")
        }
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
                    detail: "This file is new, binary, or unchanged against HEAD.")
            } else {
                DiffTextView(diff: model.diffText, title: selection.path)
            }
        } else {
            DiffPlaceholder(
                text: "No file selected",
                icon: "doc.plaintext",
                detail: "Pick a changed file above to read its diff.")
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
    @AppStorage("diffFileListHeight") private var fileListHeight: Double = 200

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()

                if let state {
                    if state.isClean {
                        DiffPlaceholder(
                            text: "No changes",
                            icon: "checkmark.circle",
                            detail: "The working tree matches HEAD.")
                    } else {
                        changeList(state)
                            .frame(height: clampedListHeight(fileListHeight, in: geometry.size.height))
                        SplitHandle(height: $fileListHeight, range: splitRange(in: geometry.size.height))
                        DiffTextView(diff: state.diff, scrollTarget: focusedPath)
                    }
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

    private func changeList(_ state: GitWorktreeState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FileListCaption(count: state.changes.count)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(state.changes) { change in
                        Button {
                            focusedPath = change.path
                        } label: {
                            FileRow(change: change, isSelected: focusedPath == change.path)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
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
        // Only reassign when changed, so quiet polls don't churn the view.
        if computed != state { state = computed }
        if showSpinner { isLoading = false }
    }
}

/// Bounds for the draggable file-list/diff split: never let the list take so
/// much room that the diff disappears in a short window.
private func splitRange(in available: CGFloat) -> ClosedRange<Double> {
    90...max(90, Double(available) - 220)
}

private func clampedListHeight(_ stored: Double, in available: CGFloat) -> CGFloat {
    let range = splitRange(in: available)
    return CGFloat(min(max(stored, range.lowerBound), range.upperBound))
}

// MARK: - File list

/// A changed-file row that keeps a sense of the file structure: the directory is
/// dimmed and the filename emphasized.
private struct FileRow: View {
    let change: GitFileChange
    let isSelected: Bool

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
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(rowFill)
        )
        // A leading bar keeps the selection readable even where the accent tint
        // is subtle (light mode, graphite accent).
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .padding(.vertical, 3)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help("\(status.label) · \(status.stagingNote) · \(change.path)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.label), \(status.stagingNote), \(change.path)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var rowFill: Color {
        if isSelected { return Color.accentColor.opacity(0.22) }
        return isHovering ? Color.primary.opacity(0.07) : .clear
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
private struct DiffRow: Identifiable {
    enum Kind { case file, hunk, addition, deletion, context, meta }

    let id: Int
    let kind: Kind
    /// The line's number in the new file (additions, context) or the old file
    /// (deletions). A single column leaves room for code in a narrow sidebar.
    let number: Int?
    let text: String
    /// The function/context suffix git puts after a hunk header, if any.
    let detail: String?
}

/// A unified diff broken into displayable rows, plus the totals the pane header
/// shows. Parsed once per distinct diff text rather than on every redraw.
private struct ParsedDiff {
    var rows: [DiffRow] = []
    var additions = 0
    var deletions = 0
    /// Gutter width sized to the widest line number in this diff.
    var gutterWidth: CGFloat = 18

    static func parse(_ diff: String, includeFileHeaders: Bool) -> ParsedDiff {
        var parsed = ParsedDiff()
        var lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() } // trailing newline

        var oldNumber = 0
        var newNumber = 0
        var widest = 0

        for line in lines {
            let id = parsed.rows.count
            if line.hasPrefix("diff --git ") {
                oldNumber = 0
                newNumber = 0
                // For a single-file diff the pane header already names the file.
                if includeFileHeaders {
                    parsed.rows.append(DiffRow(
                        id: id, kind: .file, number: nil, text: path(fromHeader: line), detail: nil))
                }
            } else if line.hasPrefix("@@") {
                let header = splitHunkHeader(line)
                if let starts = hunkStarts(header.range) {
                    oldNumber = starts.old
                    newNumber = starts.new
                }
                parsed.rows.append(DiffRow(
                    id: id, kind: .hunk, number: nil, text: header.range, detail: header.context))
            } else if line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                continue // Blob hashes and a/ b/ paths add nothing to read.
            } else if line.hasPrefix("+") {
                parsed.rows.append(DiffRow(
                    id: id, kind: .addition, number: newNumber, text: display(line.dropFirst()), detail: nil))
                parsed.additions += 1
                widest = max(widest, newNumber)
                newNumber += 1
            } else if line.hasPrefix("-") {
                parsed.rows.append(DiffRow(
                    id: id, kind: .deletion, number: oldNumber, text: display(line.dropFirst()), detail: nil))
                parsed.deletions += 1
                widest = max(widest, oldNumber)
                oldNumber += 1
            } else if line.hasPrefix(" ") || line.isEmpty {
                parsed.rows.append(DiffRow(
                    id: id, kind: .context, number: newNumber, text: display(line.dropFirst()), detail: nil))
                widest = max(widest, newNumber)
                oldNumber += 1
                newNumber += 1
            } else {
                // "new file mode", "Binary files … differ", "\ No newline …".
                parsed.rows.append(DiffRow(id: id, kind: .meta, number: nil, text: line, detail: nil))
            }
        }

        // Monospaced digits are ~6pt wide at 10pt; pad so the column isn't tight.
        parsed.gutterWidth = CGFloat(max(2, String(widest).count)) * 6.5 + 4
        return parsed
    }

    /// "diff --git a/x b/x" → "x" (the post-rename path).
    private static func path(fromHeader line: String) -> String {
        if let separator = line.range(of: " b/") {
            return String(line[separator.upperBound...])
        }
        return String(line.dropFirst("diff --git ".count))
    }

    /// Splits "@@ -1,7 +1,9 @@ func foo()" into the range and its trailing
    /// context, which is usually the enclosing function — worth showing.
    private static func splitHunkHeader(_ line: String) -> (range: String, context: String?) {
        let afterMarker = line.index(line.startIndex, offsetBy: 2)
        guard let close = line.range(of: "@@", options: [], range: afterMarker..<line.endIndex) else {
            return (line, nil)
        }
        let range = String(line[line.startIndex..<close.upperBound])
        let context = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
        return (range, context.isEmpty ? nil : context)
    }

    /// First line number on each side of "@@ -12,7 +14,9 @@".
    private static func hunkStarts(_ range: String) -> (old: Int, new: Int)? {
        let tokens = range.split(separator: " ")
        guard tokens.count >= 3,
              let old = start(ofToken: tokens[1]),
              let new = start(ofToken: tokens[2])
        else { return nil }
        return (old, new)
    }

    /// "-12,7" → 12.
    private static func start(ofToken token: Substring) -> Int? {
        guard let digits = token.dropFirst().split(separator: ",").first else { return nil }
        return Int(digits)
    }

    /// Tabs render at unpredictable widths in `Text`, so expand them to keep the
    /// monospaced grid honest; CRs from Windows files would show as boxes.
    private static func display(_ text: Substring) -> String {
        String(text)
            .replacingOccurrences(of: "\t", with: "    ")
            .replacingOccurrences(of: "\r", with: "")
    }
}

/// A scrollable unified-diff view with a line-number gutter, tinted +/- rows and
/// styled hunk headers. The sidebar is narrow, so lines soft-wrap under the
/// gutter rather than forcing a horizontal scroll to read the ends of lines.
private struct DiffTextView: View {
    let diff: String
    /// Non-nil for a single-file diff: named in the pane header, which also lets
    /// the redundant per-file header rows be dropped.
    var title: String?
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
                .onChange(of: scrollTarget) { target in
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
        .onChange(of: diff) { _ in reparse() }
    }

    private var paneHeader: some View {
        HStack(spacing: 6) {
            if let title {
                Text(structuredPath(title))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(title)
            } else {
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
        parsed = ParsedDiff.parse(diff, includeFileHeaders: title == nil)
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
            .help("Drag to resize the file list")
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
