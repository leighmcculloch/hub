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

    private let exe: ExeService
    private let config: AppConfig

    /// Nonisolated so it can be constructed from plain (non-main-actor) contexts
    /// like `Workspace.makeProvisioner()`; it only assigns stored properties.
    nonisolated init(exe: ExeService, config: AppConfig) {
        self.exe = exe
        self.config = config
    }

    var filteredRepos: [GitHubRepo] {
        guard !search.isEmpty else { return repos }
        return repos.filter { $0.fullName.localizedCaseInsensitiveContains(search) }
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

            let vmName = "tab-" + UUID().uuidString.prefix(8).lowercased()
            log("Creating VM \(vmName) (tags: \(tags.joined(separator: ", ")))…")
            let vm = try await exe.createVM(name: vmName, tags: tags)
            let destination = vm.ssh_dest ?? "\(vmName).exe.xyz"

            log("VM ready at \(destination). Opening SSH session…")
            let bootstrap = Self.bootstrap(setupScript: config.data.setupScript, repos: chosen)
            phase = .done

            let title = chosen.count == 1
                ? (chosen[0].split(separator: "/").last.map(String.init) ?? vmName)
                : "\(chosen.count) repos"
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

    /// Build the remote command run over SSH: decode and execute a bootstrap
    /// script (setup script, then a `git clone` per repo through the exe.dev
    /// GitHub proxy), then drop into an interactive login shell.
    ///
    /// The script is base64-encoded so an arbitrary multi-line user setup script
    /// survives the trip through SSH argument and remote-shell parsing.
    static func bootstrap(setupScript: String, repos: [String]) -> String {
        var script = "#!/usr/bin/env bash\n"
        script += setupScript
        script += "\n"
        for repo in repos {
            script += "git clone https://github.int.exe.xyz/\(repo).git || true\n"
        }
        let encoded = Data(script.utf8).base64EncodedString()
        return "printf %s '\(encoded)' | base64 -d > /tmp/exe-bootstrap.sh"
            + " && chmod +x /tmp/exe-bootstrap.sh && /tmp/exe-bootstrap.sh;"
            + " exec ${SHELL:-bash} -l"
    }
}
