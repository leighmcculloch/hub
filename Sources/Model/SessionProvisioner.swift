import Combine
import Foundation

/// Drives the new-tab flow: pick repos, ensure their GitHub access, create a
/// VM tagged for those integrations, and produce the SSH launch descriptor that
/// clones the repos on connect.
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
    @Published var existingVMs: [RemoteVMRecord] = []
    @Published var loadingVMs = false

    // Model picker state. The catalogue is remote, so it can be slow or absent;
    // "Custom" is always offered regardless.
    @Published var models: [GatewayModel] = []
    @Published var modelsError: String?
    @Published var loadingModels = false

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
    nonisolated(unsafe) private let provider: VMProvider
    nonisolated(unsafe) private let config: AppConfig

    /// Nonisolated so it can be constructed from plain (non-main-actor) contexts
    /// like `Workspace.makeProvisioner()`; it only assigns stored properties.
    nonisolated init(provider: VMProvider, config: AppConfig) {
        self.provider = provider
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
        if let manual = RepoReference.normalize(manualRepo) { set.insert(manual) }
        return set.sorted()
    }

    /// Whether the typed text will be used, for the hint under the field.
    var manualRepoIsUsable: Bool {
        manualRepo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || RepoReference.normalize(manualRepo) != nil
    }

    /// The catalogue plus whatever is already selected: a model that has since
    /// left the catalogue would otherwise leave the picker showing nothing.
    var modelOptions: [GatewayModel] {
        guard let selected = config.data.model, !models.contains(selected) else { return models }
        return models + [selected]
    }

    func loadModels() async {
        loadingModels = true
        let result = await provider.listModels()
        models = result.models
        modelsError = result.error
        loadingModels = false
    }

    func loadRepos() async {
        // Show the last fetch right away so the picker isn't blank while the
        // network answers; the list refreshes seamlessly when this returns.
        if repos.isEmpty, let cached = RepoCache.read() {
            repos = cached
        }
        loadingRepos = true
        let result = await GitHubRepos.list()
        loadingRepos = false
        if result.error == nil {
            repos = result.repos
            reposError = nil
        } else if repos.isEmpty {
            // Nothing cached to fall back on — show the failure.
            reposError = result.error
        } else {
            // A stale list beats a blank one, so keep the cached repos and drop
            // the error rather than wiping the picker on a transient failure.
            reposError = nil
        }
    }

    /// Existing VMs on the account, offered for reconnection.
    func loadExistingVMs() async {
        loadingVMs = true
        existingVMs = (try? await provider.listVMs()) ?? []
        loadingVMs = false
    }

    /// Run provisioning. On success returns the launch descriptor and a tab
    /// title; on failure sets `errorMessage` and returns nil.
    /// `gitIdentity` seeds the VM's commit identity. Repos are optional — a
    /// session with none is just a bare VM.
    func provision(gitIdentity: (name: String, email: String)? = nil) async
        -> (launch: TerminalSession.Launch, title: String, vmName: String, webURL: String?, autoName: Bool)?
    {
        let chosen = chosenRepos

        phase = .working
        statusLines = []
        errorMessage = nil

        do {
            log("Preparing GitHub access for \(chosen.count) repo\(chosen.count == 1 ? "" : "s")…")
            let setup = try await provider.prepareGitHub(repos: chosen)
            let tags = setup.tags

            // Re-read the VM list rather than trusting `existingVMs`, which is
            // only populated while the reconnect list is on screen. A failed
            // lookup just means no names to avoid.
            let taken = Set((try? await provider.listVMs())?.map(\.name) ?? [])
            let vmName = Bootstrap.uniqueVMName(from: sessionName, existing: taken)
            let sessionEnvironment = config.data.selectedEnvironment
            let model = config.data.model
            let gateway = model.map { GatewaySelection(model: $0, wiring: provider.harnessWiring(for: $0)) }
            // A session nobody named gets its name from the work: the VM renames
            // itself once the agent has a prompt to name it after. A name that
            // was typed is left alone, hostname and all. Providers without
            // auto-naming never arm, so an unnamed sprites session keeps its
            // generated name.
            let unnamed = sessionName.trimmingCharacters(in: .whitespaces).isEmpty
            let autoNameToken = (unnamed && provider.supportsAutoNaming) ? await renameToken() : nil
            // The model's variables come last so they win: pointing Claude Code
            // at the gateway means blanking the token the environment sets.
            let environment = EnvVar.merged([
                config.data.globalEnvironment,
                sessionEnvironment.environment,
                setup.cloneEnvironment,
                gateway.map { $0.wiring.hostEnvironment } ?? [],
                autoNameToken.map { [EnvVar(key: AutoName.tokenVariable, value: $0)] } ?? [],
            ])
            var creating = "Creating VM \(vmName) (tags: \(tags.joined(separator: ", "))"
            creating += "; environment: \(sessionEnvironment.name)"
            if let model {
                creating += "; model: \(model.label)"
            }
            if !environment.isEmpty {
                creating += "; env: \(environment.map(\.key).joined(separator: ", "))"
            }
            log(creating + ")…")
            let vm = try await provider.createVM(name: vmName, tags: tags, environment: environment)
            let destination = vm.destination

            log("VM ready at \(destination). Opening session…")
            let bootstrap = Bootstrap.command(
                setupScript: sessionEnvironment.setupScript,
                claudeSettings: config.data.claudeSettings,
                repos: chosen,
                clone: setup.clone,
                startCommand: sessionEnvironment.startCommand,
                gitIdentity: gitIdentity,
                gateway: gateway,
                hostEnvironmentSetup: provider.hostEnvironmentSetup(environment),
                autoName: autoNameToken != nil
            )
            phase = .done

            let trimmedName = sessionName.trimmingCharacters(in: .whitespaces)
            let title = !trimmedName.isEmpty ? trimmedName : vmName
            return (.remote(destination: destination, bootstrap: bootstrap),
                    title, vmName, vm.webURL, autoNameToken != nil)
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
            return nil
        }
    }

    /// The token a VM renames itself with, cached between sessions: minting it
    /// creates a key on the account, so one is reused until it nears expiry.
    ///
    /// Nil when the account's token may not mint one. Auto-naming is a
    /// convenience, so that costs the name and nothing else — the session is
    /// created either way, with a line on the log saying what to change.
    private func renameToken() async -> String? {
        let cached = config.data.renameToken
        if !cached.isEmpty, !AutoName.tokenIsStale(minted: config.data.renameTokenMinted) {
            return cached
        }
        log("Minting a rename-only token, so the VM can name itself…")
        do {
            let token = try await provider.generateRenameToken()
            config.data.renameToken = token
            config.data.renameTokenMinted = Date()
            return token
        } catch {
            log("Auto-naming off (\(error.localizedDescription)) — add"
                + " `ssh-key generate-api-key` to your exe.dev token's cmds.")
            return nil
        }
    }

    private func log(_ line: String) {
        statusLines.append(line)
    }

}
