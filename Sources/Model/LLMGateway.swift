import Foundation

/// A model offered by a provider's LLM gateway.
struct GatewayModel: Codable, Hashable, Identifiable {
    /// The gateway's provider, e.g. `anthropic` or `fireworks`.
    var provider: String

    /// The id the gateway routes on. Passed to the harnesses verbatim — it is
    /// the gateway's own catalogue, so its ids are what the gateway accepts,
    /// including Fireworks' `accounts/fireworks/models/…` form.
    var model: String

    var id: String { "\(provider)/\(model)" }

    /// What the picker shows. The provider qualifies models whose id doesn't
    /// name it, and only the last path component is kept, so
    /// `accounts/fireworks/models/glm-5p2` reads as `fireworks/glm-5p2`.
    var label: String {
        "\(provider)/\(model.split(separator: "/").last.map(String.init) ?? model)"
    }
}

/// A provider's LLM gateway: the model catalogue, and the configuration a
/// selected model needs on the VM. Parameterised by `LLMGatewayConfig` so the
/// same logic serves exe.dev and sprites.dev — only the base URL, provider name
/// and catalogue URL differ.
///
/// Claude Code is configured through environment variables set on the VM host;
/// Codex and pi through files written during bootstrap. Nothing here is
/// harness-specific beyond those three — a different tool on the VM is left to
/// find its own credentials.
enum LLMGateway {
    /// Variables set on the VM host, so every process sees them.
    ///
    /// Claude Code insists on an API key even where the gateway needs none, so
    /// it gets a placeholder; the OAuth token is blanked so a token set by the
    /// session environment can't win over the gateway.
    static func environment(for model: GatewayModel, config: LLMGatewayConfig) -> [EnvVar] {
        [
            EnvVar(key: "ANTHROPIC_API_KEY", value: "implicit"),
            EnvVar(key: "CLAUDE_CODE_OAUTH_TOKEN", value: ""),
            EnvVar(key: "ANTHROPIC_BASE_URL", value: config.baseURL),
            EnvVar(key: "ANTHROPIC_MODEL", value: model.model),
        ]
    }

    /// `~/.codex/config.toml`: the gateway as a model provider, selected, with
    /// approvals and the sandbox turned off — the same "just run it" stance
    /// Claude Code gets via `permissions.defaultMode: bypassPermissions`.
    static func codexConfig(for model: GatewayModel, config: LLMGatewayConfig) -> String {
        """
        model = \(tomlString(model.model))
        model_provider = \(tomlString(config.providerName))
        approval_policy = "never"
        sandbox_mode = "danger-full-access"

        [model_providers.\(config.providerName)]
        name = \(tomlString(config.providerName))
        base_url = \(tomlString("\(config.baseURL)/v1"))
        requires_openai_auth = false
        """
    }

    /// The `providers` entry merged into `~/.pi/agent/models.json`.
    ///
    /// Anthropic models are reached over the Messages API and everything else
    /// over Chat Completions, matching how the gateway routes them. The api key
    /// is the same placeholder Claude Code gets: pi hides models it believes
    /// have no credentials, and the gateway needs none.
    static func piProvider(for model: GatewayModel, config: LLMGatewayConfig) -> String {
        json([
            config.providerName: [
                "baseUrl": "\(config.baseURL)/v1",
                "api": model.provider == "anthropic" ? "anthropic-messages" : "openai-completions",
                "apiKey": "implicit",
                "models": [["id": model.model]],
            ],
        ])
    }

    /// The keys merged into `~/.pi/agent/settings.json`, so pi starts on the
    /// chosen model rather than only offering it under `/model`.
    static func piSettings(for model: GatewayModel, config: LLMGatewayConfig) -> String {
        json(["defaultProvider": config.providerName, "defaultModel": model.model])
    }

    /// Bundle the env vars and Codex/pi config into a `HarnessWiring` for a
    /// model. exe.dev's wiring in one place, used by `ExeProvider` and tests.
    static func wiring(for model: GatewayModel, config: LLMGatewayConfig) -> HarnessWiring {
        HarnessWiring(
            marker: config.providerName,
            setup: "",
            hostEnvironment: environment(for: model, config: config),
            codexConfig: codexConfig(for: model, config: config),
            piProvider: piProvider(for: model, config: config),
            piSettings: piSettings(for: model, config: config))
    }

    // MARK: - Catalogue

    /// The models on offer, or a readable reason there are none.
    static func list(config: LLMGatewayConfig) async -> (models: [GatewayModel], error: String?) {
        do {
            let (data, response) = try await URLSession.shared.data(from: config.catalogURL)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return ([], "Couldn’t load the model list (HTTP \(status)).")
            }
            return (try models(from: data), nil)
        } catch {
            return ([], "Couldn’t load the model list: \(error.localizedDescription)")
        }
    }

    /// Chat models only. The catalogue also lists embedding and reranker
    /// models, which no harness can be pointed at; they're told apart by their
    /// output type rather than by guessing from the name.
    static func models(from data: Data) throws -> [GatewayModel] {
        try JSONDecoder().decode(Catalog.self, from: data).providers.flatMap { provider in
            provider.models
                .filter { $0.output?.contains("text") ?? true }
                .map { GatewayModel(provider: provider.id, model: $0.id) }
        }
    }

    private struct Catalog: Decodable {
        let providers: [Provider]

        struct Provider: Decodable {
            let id: String
            let models: [Model]

            struct Model: Decodable {
                let id: String
                let output: [String]?
            }
        }
    }

    // MARK: - Serialization

    /// Sorted so the files written on the VM don't churn between runs.
    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// A TOML basic string. Model ids arrive from a remote catalogue, so they
    /// are escaped rather than trusted to be quote-free.
    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
