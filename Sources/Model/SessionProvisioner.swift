import Combine
import Foundation

/// Drives the new-tab flow: pick repos, ensure their exe.dev GitHub
/// integrations, create a VM tagged for those integrations, and produce the SSH
/// launch descriptor that clones the repos on connect.
@MainActor
final class SessionProvisioner: ObservableObject {
    enum Phase: Equatable {
        case pickingRepos
        case working
        case failed
        case done
    }

    @Published var phase: Phase = .pickingRepos

    /// User-supplied name; also used as the VM name.
    @Published var sessionName = ""

    // Existing VMs that can be reopened.
    @Published var existingVMs: [ExeVM] = []
    @Published var loadingVMs = false

    // Repo picker state.
    @Published var repos: [GitHubRepo] = []
    @Published var reposError: String?
    @Published var loadingRepos = false
    @Published var search = ""
    @Published var selected: Set<String> = []
    @Published var manualRepo = ""

    // Provisioning state.
    @Published var statusLines: [String] = []
    @Published var errorMessage: String?

    // Assigned only by the nonisolated init below, before this object is shared,
    // and read only from main-actor methods afterwards. Marked nonisolated so
    // that init doesn't have to cross into the main actor to store them (an
    // error under the Swift 6 language mode).
    nonisolated(unsafe) private let exe: ExeService
    nonisolated(unsafe) private let config: AppConfig

    /// Nonisolated so it can be constructed from plain (non-main-actor) contexts
    /// like `Workspace.makeProvisioner()`; it only assigns stored properties.
    nonisolated init(exe: ExeService, config: AppConfig) {
        self.exe = exe
        self.config = config
    }

    /// Filtered by the search box, with selected repos hoisted to the top so the
    /// current selection stays visible and grouped.
    var filteredRepos: [GitHubRepo] {
        let matching = search.isEmpty
            ? repos
            : repos.filter { $0.fullName.localizedCaseInsensitiveContains(search) }
        let chosen = matching.filter { selected.contains($0.fullName) }
        let rest = matching.filter { !selected.contains($0.fullName) }
        return chosen + rest
    }

    /// The repos to provision: checked ones plus a manually typed one.
    var chosenRepos: [String] {
        var set = selected
        let manual = manualRepo.trimmingCharacters(in: .whitespaces)
        if manual.contains("/") { set.insert(manual) }
        return set.sorted()
    }

    func loadRepos() async {
        loadingRepos = true
        reposError = nil
        let result = await GitHubRepos.list()
        repos = result.repos
        reposError = result.error
        loadingRepos = false
    }

    /// Existing VMs on the account, offered for reconnection.
    func loadExistingVMs() async {
        loadingVMs = true
        existingVMs = (try? await exe.listVMs()) ?? []
        loadingVMs = false
    }

    /// Run provisioning. On success returns the launch descriptor and a tab
    /// title; on failure sets `errorMessage` and returns nil.
    func provision() async -> (launch: TerminalSession.Launch, title: String)? {
        let chosen = chosenRepos
        guard !chosen.isEmpty else {
            errorMessage = "Select at least one repository (or type owner/repo)."
            return nil
        }

        phase = .working
        statusLines = []
        errorMessage = nil

        do {
            log("Listing existing integrations…")
            let existing = try await exe.listIntegrations()

            var tags: [String] = []
            for repo in chosen {
                log("Ensuring GitHub integration for \(repo)…")
                tags.append(try await exe.ensureGithubIntegration(repo: repo, existing: existing))
            }

            let vmName = Bootstrap.vmName(from: sessionName)
            let environment = config.data.environment.filter { !$0.key.isEmpty }
            var creating = "Creating VM \(vmName) (tags: \(tags.joined(separator: ", "))"
            if !environment.isEmpty {
                creating += "; env: \(environment.map(\.key).joined(separator: ", "))"
            }
            log(creating + ")…")
            let vm = try await exe.createVM(name: vmName, tags: tags, environment: environment)
            let destination = vm.ssh_dest ?? "\(vmName).exe.xyz"

            log("VM ready at \(destination). Opening SSH session…")
            let bootstrap = Bootstrap.command(
                setupScript: config.data.setupScript,
                claudeSettings: config.data.claudeSettings,
                repos: chosen
            )
            phase = .done

            let trimmedName = sessionName.trimmingCharacters(in: .whitespaces)
            let title = !trimmedName.isEmpty ? trimmedName : vmName
            return (.ssh(destination: destination, bootstrap: bootstrap), title)
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
            return nil
        }
    }

    private func log(_ line: String) {
        statusLines.append(line)
    }

}
