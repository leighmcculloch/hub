import SwiftUI

/// The new-tab flow: choose GitHub repo(s), then provision an exe.dev VM and
/// open an SSH tab that runs the setup script and clones the repos.
struct NewSessionSheet: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @StateObject private var provisioner: SessionProvisioner

    /// Creating a new VM and reopening an existing one are separate tasks with
    /// separate controls; splitting them keeps either column short enough to
    /// scan instead of stacking both in one sheet.
    private enum Mode: Hashable {
        case create
        case reopen
    }

    @State private var mode: Mode = .create

    init(workspace: Workspace) {
        self.workspace = workspace
        _provisioner = StateObject(wrappedValue: workspace.makeProvisioner())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            switch provisioner.phase {
            case .pickingRepos:
                picker
            case .working, .done:
                progressView
            case .failed:
                failureView
            }

            Divider()
            footer
        }
        .frame(width: 580, height: 640)
        .task {
            await provisioner.loadRepos()
            await provisioner.loadExistingVMs()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("New VM Session")
                .font(.headline)
            Text("Each tab provisions an exe.dev VM and clones the selected repos into its home directory.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    // MARK: - Picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Mode", selection: $mode) {
                Text("Create VM").tag(Mode.create)
                Text("Reopen VM").tag(Mode.reopen)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(14)

            switch mode {
            case .create: createForm
            case .reopen: existingSessions
            }
        }
    }

    // MARK: - Create

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("Session name")
                TextField("optional", text: $provisioner.sessionName)
                    .textFieldStyle(.roundedBorder)
                // The name is slugified into the VM name, so show the result
                // when it differs from what was typed.
                Text(vmNamePreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)

            if workspace.config.effectiveToken.isEmpty {
                tokenWarning
                    .padding(.horizontal, 14)
            }

            VStack(alignment: .leading, spacing: 6) {
                repoHeader
                searchField
            }
            .padding(.horizontal, 14)

            repoList

            manualEntry
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
    }

    /// Section title plus a running summary of the selection, so the count and
    /// the names are visible without scrolling the list back to the top.
    private var repoHeader: some View {
        let chosen = provisioner.chosenRepos
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("Repositories to clone")
                Spacer()
                if chosen.isEmpty {
                    Text("none selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(chosen.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Clear") {
                        provisioner.selected.removeAll()
                        provisioner.manualRepo = ""
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            if !chosen.isEmpty {
                Text(chosen.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter repositories…", text: $provisioner.search)
                .textFieldStyle(.plain)
            if !provisioner.search.isEmpty {
                Button {
                    provisioner.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
    }

    @ViewBuilder
    private var repoList: some View {
        if provisioner.loadingRepos {
            centered { ProgressView("Loading repositories…") }
        } else if provisioner.repos.isEmpty {
            centered { emptyRepoList }
        } else if provisioner.filteredRepos.isEmpty {
            centered {
                emptyState(
                    icon: "magnifyingglass",
                    title: "No matches",
                    detail: "No repository matches “\(provisioner.search)”."
                ) {
                    Button("Clear Filter") { provisioner.search = "" }
                }
            }
        } else {
            List {
                ForEach(provisioner.filteredRepos) { repo in
                    Toggle(isOn: binding(for: repo.fullName)) {
                        repoRow(repo)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .listStyle(.inset)
        }
    }

    /// No repos at all: either listing failed (token/network) or the account has
    /// none. Both are recoverable, so offer a retry alongside the reason.
    private var emptyRepoList: some View {
        emptyState(
            icon: provisioner.reposError == nil ? "tray" : "exclamationmark.triangle",
            title: provisioner.reposError == nil ? "No repositories found" : "Couldn’t list repositories",
            detail: provisioner.reposError ?? "Nothing to clone from this account — add one by name below."
        ) {
            Button("Try Again") {
                Task { await provisioner.loadRepos() }
            }
        }
    }

    /// Owner dimmed so the repository name is what the eye lands on.
    private func repoRow(_ repo: GitHubRepo) -> some View {
        let parts = repo.fullName.split(separator: "/", maxSplits: 1)
        return HStack(spacing: 6) {
            Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(width: 12)
            if parts.count == 2 {
                Text(String(parts[0]) + "/").foregroundStyle(.secondary)
                Text(String(parts[1]))
            } else {
                Text(repo.fullName)
            }
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Not listed? Add by name")
            TextField("owner/repo or a GitHub URL", text: $provisioner.manualRepo)
                .textFieldStyle(.roundedBorder)
            // Text that can't be read as a repo is ignored by `chosenRepos`, so
            // say so rather than silently dropping it.
            if !provisioner.manualRepoIsUsable {
                Label("Use the owner/repo form, e.g. apple/swift.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let normalized = RepoReference.normalize(provisioner.manualRepo),
                      normalized != manualRepoTrimmed {
                // A pasted URL is silently rewritten; show what will be cloned.
                Label("Will use \(normalized)", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tokenWarning: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 1) {
                Text("No exe.dev token configured").fontWeight(.semibold)
                Text("Set one in Settings (⌘,) or supply EXE_DEV_TOKEN. Creating a VM will fail without it.")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }

    // MARK: - Reopen

    /// Existing VMs on the account — reopen one to continue where you left off.
    private var existingSessions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("VMs on your account")
                Spacer()
                Button {
                    Task { await provisioner.loadExistingVMs() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(provisioner.loadingVMs)
            }
            .padding(.horizontal, 14)

            if provisioner.loadingVMs {
                centered { ProgressView("Loading VMs…") }
            } else if provisioner.existingVMs.isEmpty {
                centered {
                    emptyState(
                        icon: "server.rack",
                        title: "No existing VMs",
                        detail: "Create one from the Create VM tab."
                    ) {
                        Button("Create VM") { mode = .create }
                    }
                }
            } else {
                List {
                    ForEach(provisioner.existingVMs) { vm in
                        vmRow(vm)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(.bottom, 10)
    }

    private func vmRow(_ vm: ExeVM) -> some View {
        let running = vm.status == "running"
        return HStack(spacing: 8) {
            Circle()
                .fill(running ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.vm_name ?? vm.ssh_dest ?? "unknown")
                Text(vmSubtitle(vm))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Open") {
                workspace.reopen(vm: vm)
                dismiss()
            }
        }
        .padding(.vertical, 2)
    }

    /// Status and region on one dim line, so the VM name stays the only
    /// full-strength text in the row.
    private func vmSubtitle(_ vm: ExeVM) -> String {
        var parts: [String] = []
        if let status = vm.status, !status.isEmpty { parts.append(status) }
        if let region = vm.region, !region.isEmpty { parts.append(region) }
        return parts.isEmpty ? "unknown status" : parts.joined(separator: " · ")
    }

    // MARK: - Progress / failure

    /// Steps already logged are done; the last one is still running while the
    /// phase is `.working`, so it gets a spinner rather than a checkmark.
    private var progressView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(provisioner.statusLines.enumerated()), id: \.offset) { index, line in
                stepRow(line, state: stepState(at: index, failed: false))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var failureView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(provisioner.statusLines.enumerated()), id: \.offset) { index, line in
                    stepRow(line, state: stepState(at: index, failed: true))
                }
                if let error = provisioner.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.1)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    private enum StepState {
        case done
        case running
        case failed
    }

    /// The last logged line is the step that is either in flight or the one that
    /// blew up; everything before it completed.
    private func stepState(at index: Int, failed: Bool) -> StepState {
        let isLast = index == provisioner.statusLines.count - 1
        guard isLast else { return .done }
        if failed { return .failed }
        return provisioner.phase == .working ? .running : .done
    }

    @ViewBuilder
    private func stepRow(_ line: String, state: StepState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .running:
                    ProgressView().controlSize(.small)
                case .failed:
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 16)
            if state == .done {
                Text(line).font(.callout).foregroundStyle(.secondary)
            } else {
                Text(line).font(.callout)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if mode == .create || provisioner.phase != .pickingRepos {
                // Say why the button is dead instead of leaving it greyed out
                // with no explanation.
                if let reason = disabledReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if provisioner.phase == .failed {
                    Button("Back") { provisioner.phase = .pickingRepos }
                }
                Button(provisioner.phase == .failed ? "Retry" : "Create Session") {
                    Task { await create() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(provisioner.phase == .working)
            }
        }
        .padding(14)
    }

    /// Repos are optional — a session with none is just a bare VM — so there is
    /// nothing to block on.
    private var disabledReason: String? { nil }

    @MainActor
    private func create() async {
        if let (launch, title, vmName) = await provisioner.provision(gitIdentity: workspace.gitIdentity) {
            workspace.addSession(title: title, launch: launch, vmName: vmName)
            dismiss()
        }
    }

    // MARK: - Helpers

    private var manualRepoTrimmed: String {
        provisioner.manualRepo.trimmingCharacters(in: .whitespaces)
    }

    /// Empty names get a randomly generated VM name at provision time, so only
    /// preview a name the user actually typed.
    private var vmNamePreview: String {
        let trimmed = provisioner.sessionName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Also used as the VM name; generated if left blank." }
        return "VM name: \(Bootstrap.vmName(from: trimmed))"
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func emptyState<Action: View>(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            action()
                .padding(.top, 2)
        }
        .padding(.horizontal, 32)
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func binding(for repo: String) -> Binding<Bool> {
        Binding(
            get: { provisioner.selected.contains(repo) },
            set: { isOn in
                if isOn { provisioner.selected.insert(repo) }
                else { provisioner.selected.remove(repo) }
            }
        )
    }
}
