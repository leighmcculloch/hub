import Foundation

/// exe.dev as a `VMProvider`: the HTTPS `/exec` API for VM lifecycle and GitHub
/// integrations, the `llm.int.exe.xyz` gateway, SSH against `<name>.exe.xyz`,
/// and the reflection endpoint that lets a VM name itself.
final class ExeProvider: VMProvider {
    let id: VMProviderID = .exe
    let displayName = "exe.dev"
    let defaultBrowserURL = "https://exe.dev"
    let supportsAutoNaming = true
    let tokenEnvVar = "EXE_DEV_TOKEN"

    private let service: ExeService
    private let tokenProvider: () -> String

    init(tokenProvider: @escaping () -> String = { "" }) {
        self.tokenProvider = tokenProvider
        service = ExeService(client: ExeClient(tokenProvider: tokenProvider))
    }

    func effectiveToken() -> String { tokenProvider() }

    // MARK: - LLM gateway

    func listModels() async -> (models: [GatewayModel], error: String?) {
        await LLMGateway.list(config: .exe)
    }

    func harnessWiring(for model: GatewayModel) -> HarnessWiring {
        LLMGateway.wiring(for: model, config: .exe)
    }

    // MARK: - VM lifecycle

    func listVMs() async throws -> [RemoteVMRecord] {
        try await service.listVMs().map(Self.record(from:))
    }

    func createVM(name: String, tags: [String], environment: [EnvVar]) async throws -> RemoteVMRecord {
        let vm = try await service.createVM(name: name, tags: tags, environment: environment)
        return Self.record(from: vm)
    }

    func deleteVM(name: String) async throws {
        try await service.deleteVM(name: name)
    }

    // MARK: - GitHub

    /// Ensure a GitHub integration exists for each repo (creating one that acts
    /// as the user if not) and return the per-repo tags that bind them to the
    /// new VM. exe.dev brokers clone access through those integrations and the
    /// `github.int.exe.xyz` proxy, so no clone credentials go in the environment.
    func prepareGitHub(repos: [String]) async throws -> GitHubSetup {
        guard !repos.isEmpty else {
            return GitHubSetup(tags: [], cloneEnvironment: [], clone: .exe)
        }
        let existing = try await service.listIntegrations()
        var tags: [String] = []
        for repo in repos {
            tags.append(try await service.ensureGithubIntegration(repo: repo, existing: existing))
        }
        return GitHubSetup(tags: tags, cloneEnvironment: [], clone: .exe)
    }

    // MARK: - Auto-naming

    func generateRenameToken() async throws -> String {
        try await service.generateRenameToken()
    }

    // MARK: - Naming and reachability

    func destination(forVMName name: String) -> String { "\(name).exe.xyz" }

    func webURL(forDestination destination: String) -> String? { "https://\(destination)" }

    /// Shelley — exe.dev's own web agent — served on the VM's port 9999.
    func shelleyURL(forDestination destination: String) -> String? { "https://\(destination):9999/" }

    /// The reflection integration — attached to every VM on an account by
    /// default — publishes the VM's current name at the top level of its index.
    let reflectionNameCommand: String? = "curl -fsS --max-time 5 https://reflection.int.exe.xyz/"

    func parseReflectedName(_ output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String,
              !name.isEmpty
        else { return nil }
        return name
    }

    // MARK: - Transport

    func transport(forDestination destination: String) -> RemoteTransport {
        SSHTransport(destination: destination)
    }

    // MARK: - Mapping

    /// An `ExeVM` as the app-agnostic `RemoteVMRecord`. `ssh_dest` is the
    /// transport handle; the web URL is the SSH host over HTTPS, matching what
    /// `TerminalSession.webURL` always produced.
    static func record(from vm: ExeVM) -> RemoteVMRecord {
        let name = vm.vm_name ?? vm.ssh_dest ?? "unknown"
        let destination = vm.ssh_dest ?? (vm.vm_name.map { "\($0).exe.xyz" } ?? "unknown")
        return RemoteVMRecord(
            name: name,
            destination: destination,
            webURL: "https://\(destination)",
            status: vm.status)
    }
}
