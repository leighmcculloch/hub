import XCTest
@testable import ExeDesktopApp

/// The exe.dev LLM gateway: reading its catalogue, and the configuration a
/// chosen model turns into. The configuration lands on a VM where a mistake is
/// only visible as a harness that can't reach a model, so the shapes are pinned
/// here.
final class LLMGatewayTests: XCTestCase {

    /// Trimmed from the real https://exe.dev/llm-gateway-models.json, keeping
    /// one of each thing that has to be handled: a plain id, a path-shaped
    /// Fireworks id, and a non-chat model.
    private let catalog = """
    {
      "schemaVersion": 1,
      "providers": [
        {
          "id": "anthropic",
          "path": "anthropic",
          "models": [
            { "id": "claude-opus-5", "input": ["text"], "output": ["text"] }
          ]
        },
        {
          "id": "openai",
          "path": "openai/v1",
          "models": [
            { "id": "gpt-5.5", "input": ["text"], "output": ["text"] },
            { "id": "text-embedding-3-small", "type": "embedding", "output": ["embedding"] }
          ]
        },
        {
          "id": "fireworks",
          "path": "fireworks/inference/v1",
          "models": [
            { "id": "accounts/fireworks/models/glm-5p2", "output": ["text"] },
            { "id": "accounts/fireworks/models/qwen3-reranker-8b", "output": ["ranking"] }
          ]
        }
      ]
    }
    """

    private func models() throws -> [GatewayModel] {
        try LLMGateway.models(from: Data(catalog.utf8))
    }

    // MARK: - Catalogue

    /// The id is taken verbatim: it's the gateway's own catalogue, so its ids
    /// are what the gateway routes on — including Fireworks' long form.
    func testEveryChatModelIsOfferedWithItsProvider() throws {
        XCTAssertEqual(try models().map(\.id), [
            "anthropic/claude-opus-5",
            "openai/gpt-5.5",
            "fireworks/accounts/fireworks/models/glm-5p2",
        ])
        XCTAssertEqual(try models().map(\.model).last, "accounts/fireworks/models/glm-5p2")
    }

    /// Embedding and reranker models can't be a harness's model. They're told
    /// apart by their output type rather than by guessing from the name.
    func testModelsThatDontOutputTextAreLeftOut() throws {
        let ids = try models().map(\.model)
        XCTAssertFalse(ids.contains("text-embedding-3-small"))
        XCTAssertFalse(ids.contains { $0.contains("reranker") })
    }

    /// The picker is read at a glance, so the provider qualifies the name and
    /// the Fireworks path is dropped.
    func testTheLabelIsTheProviderAndTheLastPathComponent() throws {
        XCTAssertEqual(try models().map(\.label), [
            "anthropic/claude-opus-5",
            "openai/gpt-5.5",
            "fireworks/glm-5p2",
        ])
    }

    /// The catalogue gains fields over time; an unknown one must not empty the
    /// list.
    func testUnknownFieldsAreIgnored() throws {
        let data = Data("""
        {"providers":[{"id":"xai","path":"xai/v1","models":[
          {"id":"grok-4.5","cost":{"input":3},"somethingNew":true}
        ]}],"schemaVersion":2}
        """.utf8)
        XCTAssertEqual(try LLMGateway.models(from: data).map(\.model), ["grok-4.5"])
    }

    func testAMalformedCatalogThrows() {
        XCTAssertThrowsError(try LLMGateway.models(from: Data("not json".utf8)))
    }

    // MARK: - Claude Code

    /// Claude Code reads these from the VM host. The placeholder key and the
    /// blanked token are both load-bearing: it refuses to run without a key,
    /// and a token left set would be used ahead of the gateway.
    func testClaudeCodeVariablesPointAtTheGateway() {
        let model = GatewayModel(provider: "anthropic", model: "claude-opus-5")
        let variables = Dictionary(
            uniqueKeysWithValues: LLMGateway.environment(for: model).map { ($0.key, $0.value) })

        XCTAssertEqual(variables["ANTHROPIC_API_KEY"], "implicit")
        XCTAssertEqual(variables["CLAUDE_CODE_OAUTH_TOKEN"], "")
        XCTAssertEqual(variables["ANTHROPIC_BASE_URL"], "https://llm.int.exe.xyz")
        XCTAssertEqual(variables["ANTHROPIC_MODEL"], "claude-opus-5")
    }

    /// Whatever the provider, the model reaching Claude Code is the gateway's
    /// id, not the label the picker shows.
    func testTheModelVariableIsTheGatewayID() {
        let model = GatewayModel(provider: "fireworks", model: "accounts/fireworks/models/glm-5p2")
        let variables = LLMGateway.environment(for: model)
        XCTAssertEqual(variables.first { $0.key == "ANTHROPIC_MODEL" }?.value,
                       "accounts/fireworks/models/glm-5p2")
    }

    // MARK: - Codex

    func testCodexConfigSelectsTheGatewayProvider() {
        let config = LLMGateway.codexConfig(
            for: GatewayModel(provider: "openai", model: "gpt-5.5"))

        XCTAssertTrue(config.contains(#"model = "gpt-5.5""#), config)
        XCTAssertTrue(config.contains(#"model_provider = "exe-llm""#), config)
        XCTAssertTrue(config.contains("[model_providers.exe-llm]"), config)
        XCTAssertTrue(config.contains(#"base_url = "https://llm.int.exe.xyz/v1""#), config)
        // No OpenAI key exists on the VM; the integration hostname is the auth.
        XCTAssertTrue(config.contains("requires_openai_auth = false"), config)
    }

    /// Model ids come from a remote catalogue, so a quote in one must not end
    /// the TOML string and leave a file Codex can't parse.
    func testCodexConfigEscapesTheModelID() {
        let config = LLMGateway.codexConfig(
            for: GatewayModel(provider: "x", model: #"we"ird\"#))
        XCTAssertTrue(config.contains(#"model = "we\"ird\\""#), config)
    }

    // MARK: - pi

    func testPiProviderDescribesTheGateway() throws {
        let provider = try piProvider(for: GatewayModel(provider: "openai", model: "gpt-5.5"))

        XCTAssertEqual(provider["baseUrl"] as? String, "https://llm.int.exe.xyz/v1")
        XCTAssertEqual(provider["apiKey"] as? String, "implicit")
        let models = try XCTUnwrap(provider["models"] as? [[String: Any]])
        XCTAssertEqual(models.map { $0["id"] as? String }, ["gpt-5.5"])
    }

    /// pi talks to each model over the API the gateway routes it on, so the
    /// Anthropic models need the Messages API rather than chat completions.
    func testPiPicksTheAPIFromTheProvider() throws {
        XCTAssertEqual(
            try piProvider(for: GatewayModel(provider: "anthropic", model: "claude-opus-5"))["api"] as? String,
            "anthropic-messages")
        XCTAssertEqual(
            try piProvider(for: GatewayModel(provider: "fireworks", model: "x"))["api"] as? String,
            "openai-completions")
    }

    /// Declaring the provider only offers the model; these make pi start on it.
    func testPiSettingsSelectTheModel() throws {
        let settings = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(LLMGateway.piSettings(
                for: GatewayModel(provider: "anthropic", model: "claude-opus-5")).utf8))
            as? [String: Any])

        XCTAssertEqual(settings["defaultProvider"] as? String, "exe-llm")
        XCTAssertEqual(settings["defaultModel"] as? String, "claude-opus-5")
    }

    /// Both pi files are merged into JSON on the VM, so they have to parse.
    func testPiConfigIsValidJSON() throws {
        let model = GatewayModel(provider: "anthropic", model: "claude-opus-5")
        for text in [LLMGateway.piProvider(for: model), LLMGateway.piSettings(for: model)] {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(text.utf8)), text)
        }
    }

    private func piProvider(for model: GatewayModel) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(
            with: Data(LLMGateway.piProvider(for: model).utf8))
        let providers = try XCTUnwrap(object as? [String: Any])
        return try XCTUnwrap(providers["exe-llm"] as? [String: Any])
    }
}
