import SwiftUI

/// The new-tab flow: choose GitHub repo(s), then provision an exe.dev VM and
/// open an SSH tab that runs the setup script and clones the repos.
struct NewSessionSheet: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @StateObject private var provisioner: SessionProvisioner

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
                repoPicker
            case .working, .done:
                progressView
            case .failed:
                failureView
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 640)
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
        .padding(14)
    }

    // MARK: - Repo picker

    private var repoPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("session name (used as the VM name)", text: $provisioner.sessionName)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 14)

            if !provisioner.existingVMs.isEmpty {
                existingSessions
            }

            if workspace.config.effectiveToken.isEmpty {
                Label("No exe.dev token configured — set one in Settings (⌘,) or via EXE_DEV_TOKEN.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
            }

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter repositories…", text: $provisioner.search)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            .padding(.horizontal, 14)

            if provisioner.loadingRepos {
                centered { ProgressView("Loading repositories…") }
            } else if provisioner.filteredRepos.isEmpty {
                centered {
                    VStack(spacing: 6) {
                        Text(provisioner.repos.isEmpty ? "No repositories listed" : "No matches")
                            .foregroundStyle(.secondary)
                        if let error = provisioner.reposError {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).padding(.horizontal)
                        }
                    }
                }
            } else {
                List {
                    ForEach(provisioner.filteredRepos) { repo in
                        Toggle(isOn: binding(for: repo.fullName)) {
                            HStack {
                                Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                Text(repo.fullName)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Text("Or add manually:").font(.caption).foregroundStyle(.secondary)
                TextField("owner/repo", text: $provisioner.manualRepo)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    /// Existing VMs on the account — reopen one to continue where you left off.
    private var existingSessions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reopen an existing session")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(provisioner.existingVMs) { vm in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(vm.status == "running" ? Color.green : Color.secondary)
                                .frame(width: 6, height: 6)
                            Text(vm.vm_name ?? vm.ssh_dest ?? "unknown")
                                .font(.system(size: 11))
                            if let region = vm.region, !region.isEmpty {
                                Text(region).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button("Open") {
                                workspace.reopen(vm: vm)
                                dismiss()
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
            .frame(maxHeight: 96)
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Progress / failure

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(provisioner.statusLines.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "checkmark.circle")
                    .font(.callout)
            }
            if provisioner.phase == .working {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var failureView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(provisioner.statusLines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.callout).foregroundStyle(.secondary)
            }
            if let error = provisioner.errorMessage {
                Label(error, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if provisioner.phase == .failed {
                Button("Back") { provisioner.phase = .pickingRepos }
            }
            Button(provisioner.phase == .failed ? "Retry" : "Create Session") {
                Task { await create() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(provisioner.phase == .working || provisioner.chosenRepos.isEmpty)
        }
        .padding(14)
    }

    @MainActor
    private func create() async {
        if let (launch, title) = await provisioner.provision() {
            workspace.addSession(title: title, launch: launch)
            dismiss()
        }
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
