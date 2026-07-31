import Foundation

/// sprites.dev as a `VMProvider`: the REST API at `api.sprites.dev` for sprite
/// lifecycle, the `sprite` CLI for running commands, GitHub cloning via a token
/// in the sprite's environment, and sprites.dev's own LLM gateway.
///
/// Unlike exe.dev, sprites.dev has no `rename`, no reflection endpoint, and no
/// Shelley, so `supportsAutoNaming` is false and `shelleyURL` is nil. VMs are
/// reached by name through the `sprite` CLI, not by a direct SSH hostname.
final class SpritesProvider: VMProvider {
    let id: VMProviderID = .sprites
    let displayName = "sprites.dev"
    let defaultBrowserURL = "https://sprites.dev"
    let supportsAutoNaming = false
    let tokenEnvVar = "SPRITE_TOKEN"

    /// The harness config is the same shape as exe.dev's (env vars + Codex/pi
    /// files) but pointed at the on-sprite proxy (`SpriteLLMProxy`), which
    /// forwards through the OpenRouter connector gateway. The catalogue is
    /// OpenRouter's public model list.
    private static let proxyGateway = LLMGatewayConfig(
        baseURL: SpriteLLMProxy.baseURL,
        providerName: "sprites-llm",
        catalogURL: URL(string: "https://openrouter.ai/api/v1/models")!)

    private let client: SpritesClient
    private let tokenProvider: () -> String

    init(tokenProvider: @escaping () -> String) {
        self.tokenProvider = tokenProvider
        self.client = SpritesClient(tokenProvider: tokenProvider)
    }

    func effectiveToken() -> String { tokenProvider() }

    // MARK: - LLM gateway

    func listModels() async -> (models: [GatewayModel], error: String?) {
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.proxyGateway.catalogURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return ([], "Couldn’t load the model list (HTTP \(status)).")
            }
            let catalog = try JSONDecoder().decode(OpenRouterCatalog.self, from: data)
            let models = catalog.data.map { GatewayModel(provider: "openrouter", model: $0.id) }
            return (models, nil)
        } catch {
            return ([], "Couldn’t load the model list: \(error.localizedDescription)")
        }
    }

    func harnessWiring(for model: GatewayModel) -> HarnessWiring {
        let config = Self.proxyGateway
        // Same env/Codex/pi shape as exe.dev, but the base URL is the proxy and
        // the setup fragment installs and starts it before the harness reads its
        // config. All sprites models route over OpenAI Chat Completions (the
        // gateway is OpenRouter), so pi uses openai-completions for every model.
        return HarnessWiring(
            marker: config.providerName,
            setup: SpriteLLMProxy.install,
            hostEnvironment: LLMGateway.environment(for: model, config: config),
            codexConfig: LLMGateway.codexConfig(for: model, config: config),
            piProvider: LLMGateway.piProvider(for: model, config: config),
            piSettings: LLMGateway.piSettings(for: model, config: config))
    }

    private struct OpenRouterCatalog: Decodable {
        let data: [Model]
        struct Model: Decodable { let id: String }
    }

    // MARK: - Host environment

    /// sprites.dev has no API to set host env, so the bootstrap writes the env
    /// into a profile (`~/.sprite-env.sh`) and sources it: once inside the
    /// bootstrap (so clones see `GITHUB_TOKEN`), and again from the first window
    /// (so the harness inherits it). Future login shells source it via
    /// `~/.profile`/`~/.bashrc`. Values are single-quoted so a `$` or backtick
    /// in one is literal, not expanded when sourced.
    func hostEnvironmentSetup(_ environment: [EnvVar]) -> String {
        let exports = environment
            .filter { !$0.key.isEmpty }
            .map { "export \($0.key)=\(Bootstrap.shellQuote($0.value))" }
            .joined(separator: "\n")
        guard !exports.isEmpty else { return "" }
        return """

        cat > "$HOME/\(Bootstrap.hostEnvFile)" <<'SPRITE_ENV_EOF'
        \(exports)
        SPRITE_ENV_EOF
        . "$HOME/\(Bootstrap.hostEnvFile)"
        for _f in "$HOME/.profile" "$HOME/.bashrc"; do [ -f "$_f" ] || continue; grep -q '\(Bootstrap.hostEnvFile)' "$_f" 2>/dev/null || printf '\\n[ -f "$HOME/\(Bootstrap.hostEnvFile)" ] && . "$HOME/\(Bootstrap.hostEnvFile)"\\n' >> "$_f"; done

        """
    }

    // MARK: - VM lifecycle

    func listVMs() async throws -> [RemoteVMRecord] {
        // The list endpoint returns names only, so GET each sprite for its URL
        // and status — the sidebar shows both, and a reopened session needs the
        // URL for its browser tab.
        let names = try await client.listNames()
        var records: [RemoteVMRecord] = []
        for name in names {
            guard let sprite = try? await client.get(name: name) else { continue }
            records.append(Self.record(from: sprite))
        }
        return records
    }

    func createVM(name: String, tags: [String], environment: [EnvVar]) async throws -> RemoteVMRecord {
        // tags are exe.dev's integration-binding mechanism; sprites.dev's
        // create body has no labels in the documented API, so they're ignored.
        // `environment` is injected by the bootstrap (see `hostEnvironmentSetup`)
        // rather than set here — sprites.dev has no host-env API.
        let sprite = try await client.create(name: name)
        // Read back the URL and status the create response may have omitted.
        let current = (try? await client.get(name: name)) ?? sprite
        return Self.record(from: current)
    }

    func deleteVM(name: String) async throws {
        try await client.delete(name: name)
    }

    // MARK: - GitHub

    /// No integration step: sprites.dev clones from github.com with a token in
    /// the sprite's environment. The token the app already discovered for the
    /// repo picker is reused, so the two providers share one GitHub credential.
    func prepareGitHub(repos: [String]) async throws -> GitHubSetup {
        guard !repos.isEmpty else {
            return GitHubSetup(tags: [], cloneEnvironment: [], clone: Self.cloneConfig(token: nil))
        }
        let token = await GitHubRepos.currentToken()
        return GitHubSetup(
            tags: [],
            cloneEnvironment: token.map { [EnvVar(key: "GITHUB_TOKEN", value: $0)] } ?? [],
            clone: Self.cloneConfig(token: token))
    }

    /// The clone config for sprites.dev: github.com, with the token carried via
    /// `http.extraheader` read from `$GITHUB_TOKEN` so it stays out of the clone
    /// URL (and out of process listings). No token means public repos only.
    static func cloneConfig(token: String?) -> Bootstrap.CloneConfig {
        Bootstrap.CloneConfig(
            urlPrefix: "https://github.com",
            extraConfig: token == nil ? "" : #"-c "http.extraheader=Authorization: Bearer $GITHUB_TOKEN""#,
            failureHint: "check the GITHUB_TOKEN in the sprite's environment, then clone again.")
    }

    // MARK: - Auto-naming (not supported)

    func generateRenameToken() async throws -> String {
        // Unreachable: `supportsAutoNaming` is false, so the provisioner never
        // calls this. Throwing rather than returning a token that could never
        // work.
        throw SpritesError(message: "sprites.dev does not support auto-naming.")
    }

    // MARK: - Naming and reachability

    /// A sprite's transport handle is its name — `sprite exec -s <name>`.
    func destination(forVMName name: String) -> String { name }

    /// A sprite's URL carries an org id the name alone doesn't, so this returns
    /// nil; the session's `webURL` is stored from the VM record at creation.
    func webURL(forDestination destination: String) -> String? { nil }

    /// sprites.dev has no Shelley web agent.
    func shelleyURL(forDestination destination: String) -> String? { nil }

    let reflectionNameCommand: String? = nil
    func parseReflectedName(_ output: String) -> String? { nil }

    // MARK: - Transport

    func transport(forDestination destination: String) -> RemoteTransport {
        SpritesCLITransport(name: destination)
    }

    // MARK: - Mapping

    static func record(from sprite: SpritesClient.Sprite) -> RemoteVMRecord {
        RemoteVMRecord(
            name: sprite.name,
            destination: sprite.name,
            webURL: sprite.url,
            status: sprite.status)
    }
}
