import Foundation

/// Which VM provider a session runs on. Persisted per session so a stored tab
/// reconnects the same way it was opened, even after the active provider in
/// Settings has changed.
enum VMProviderID: String, Codable {
    case exe
    case sprites
}

/// The configuration a chosen gateway model needs, per provider. exe.dev's
/// gateway is `https://llm.int.exe.xyz`; sprites.dev reaches OpenRouter through
/// an on-sprite proxy (see `SpritesProvider`). Both share the harness
/// configuration logic in `LLMGateway`, parameterised by this — sprites builds
/// its own wiring rather than using this directly.
struct LLMGatewayConfig: Equatable {
    let baseURL: String
    /// The name written into Codex's `model_provider` and pi's `providers` map,
    /// and the marker that says a config file on the VM is ours to rewrite.
    let providerName: String
    let catalogURL: URL

    /// exe.dev's gateway. Kept here so `ExeProvider` and the tests share one
    /// source of truth rather than re-typing the literals.
    static let exe = LLMGatewayConfig(
        baseURL: "https://llm.int.exe.xyz",
        providerName: "exe-llm",
        catalogURL: URL(string: "https://exe.dev/llm-gateway-models.json")!)
}

/// How a chosen model is wired into the VM's harnesses. Each provider builds
/// one: exe.dev points the harnesses at `llm.int.exe.xyz`; sprites.dev points
/// them at an on-sprite proxy that forwards through the OpenRouter connector
/// gateway, and includes the shell fragment that installs and starts it.
struct HarnessWiring: Equatable {
    /// The marker that says a config file on the VM is ours to rewrite (the
    /// Codex/pi provider name), and the auto-naming hook counts as ours too.
    let marker: String
    /// Shell fragment run before the harness config is written. exe.dev: empty.
    /// sprites.dev: installs and starts the LLM proxy so the harnesses can reach
    /// it when they start.
    let setup: String
    /// Variables set on the VM host, so every process sees them. Claude Code
    /// reads these; Codex and pi read files written from the strings below.
    let hostEnvironment: [EnvVar]
    /// `~/.codex/config.toml` contents.
    let codexConfig: String
    /// The `providers` entry merged into `~/.pi/agent/models.json` (JSON).
    let piProvider: String
    /// The keys merged into `~/.pi/agent/settings.json` (JSON).
    let piSettings: String
}

/// A model chosen from a provider's gateway catalogue, paired with that
/// provider's harness wiring for it. Bundled so `Bootstrap` can't be handed a
/// model without the wiring its harness configuration depends on.
struct GatewaySelection: Equatable {
    let model: GatewayModel
    let wiring: HarnessWiring
}

/// A VM, as the app cares about it regardless of provider: a name to show and
/// delete by, a `destination` the transport connects to (an SSH host for exe.dev,
/// a sprite name for sprites.dev), and an optional public web URL.
struct RemoteVMRecord: Identifiable, Equatable {
    let name: String
    let destination: String
    let webURL: String?
    let status: String?

    var id: String { name }
}

/// What cloning the chosen repos on a new VM takes. exe.dev brokers GitHub
/// access through an integration bound by a tag and a proxy URL; sprites.dev
/// puts credentials in the VM's environment and clones straight from github.com.
struct GitHubSetup: Equatable {
    /// Tags to attach the VM to (exe.dev only; empty for sprites.dev).
    let tags: [String]
    /// Environment variables the VM needs to clone with (sprites.dev only; empty
    /// for exe.dev, whose proxy needs none).
    let cloneEnvironment: [EnvVar]
    /// How `git clone` is run: URL prefix, any extra `git -c` auth, and the
    /// failure hint. exe.dev's proxy vs. sprites.dev's `$GITHUB_TOKEN`.
    let clone: Bootstrap.CloneConfig
}

/// A remote command the transport will run. The executable plus its argv —
/// `/usr/bin/ssh` with connection options for exe.dev, `sprite exec …` for
/// sprites.dev — produced by the provider's `RemoteTransport`. `TmuxClient` and
/// `RemoteGit` spawn the process from this, keeping their pipe/parse logic
/// shared and provider-agnostic.
struct RemoteProcessSpec: Equatable {
    let executable: String
    let arguments: [String]
}

/// How the app runs commands on a VM. exe.dev uses `ssh` (with ControlMaster
/// multiplexing); sprites.dev uses the `sprite` CLI. Each method is bound to one
/// destination and produces process specs the callers spawn, plus a one-line
/// summary of a failed command for the UI.
///
/// A value type so it can cross the main-actor boundary the session lives on —
/// the rename hook's first-prompt feed fires from a non-isolated context and
/// captures a transport by value.
protocol RemoteTransport: Sendable {
    /// A long-lived interactive session: `tmux -C` runs over this, its control
    /// protocol on the process's stdin/stdout.
    func interactiveSpec(command: String) -> RemoteProcessSpec
    /// A one-shot command: the diff sidebar's git calls and the rename poll.
    func oneshotSpec(command: String) -> RemoteProcessSpec
    /// One readable line for a failed one-shot, in the provider's own vocabulary
    /// (ssh's banners vs. the sprite CLI's messages).
    func summarize(stderr: String, exit: Int32) -> String
}

/// One VM provider's behaviour: how to list, create and delete VMs; how to set
/// up GitHub cloning; how to reach a model gateway; and how to run commands on a
/// VM. The rest of the app talks to this instead of `ExeService` directly, so a
/// second provider (sprites.dev) is an additional conformance rather than a fork.
protocol VMProvider: AnyObject {
    var id: VMProviderID { get }
    /// Shown in Settings and the new-session sheet.
    var displayName: String { get }
    /// The public site, for the browser tab's fallback address.
    var defaultBrowserURL: String { get }
    /// Whether sessions on this provider can name themselves from the agent's
    /// first prompt. exe.dev can (rename + reflection); sprites.dev cannot.
    var supportsAutoNaming: Bool { get }

    // MARK: - LLM gateway

    /// The models on offer from this provider's gateway, or a readable reason
    /// there are none. exe.dev reads its catalogue; sprites.dev reads
    /// OpenRouter's.
    func listModels() async -> (models: [GatewayModel], error: String?)
    /// How to wire a chosen model into the VM's harnesses (env vars, Codex/pi
    /// config, and any setup the provider needs — sprites.dev starts a proxy).
    func harnessWiring(for model: GatewayModel) -> HarnessWiring

    /// The API token: the configured value, or the environment fallback.
    func effectiveToken() -> String
    /// The environment variable the token falls back to — named in UI hints.
    var tokenEnvVar: String { get }

    // MARK: - VM lifecycle

    func listVMs() async throws -> [RemoteVMRecord]
    /// Create a VM, attaching the given tags (exe.dev binds integrations by tag;
    /// sprites.dev may use them as labels) and setting the given environment on
    /// it so every process sees it.
    func createVM(name: String, tags: [String], environment: [EnvVar]) async throws -> RemoteVMRecord
    func deleteVM(name: String) async throws

    // MARK: - GitHub

    /// Ensure the chosen repos can be cloned on a new VM, returning what the
    /// provisioner needs: tags for the VM, clone env, and the clone URL prefix.
    func prepareGitHub(repos: [String]) async throws -> GitHubSetup

    // MARK: - Auto-naming (exe.dev only)

    /// Mint the `rename`-only token a VM renames itself with. Throws on providers
    /// that don't support auto-naming — call only when `supportsAutoNaming`.
    func generateRenameToken() async throws -> String

    // MARK: - Naming and reachability

    /// The transport handle for a VM of this name: an SSH host for exe.dev, the
    /// sprite name for sprites.dev.
    func destination(forVMName name: String) -> String
    /// The VM's public web URL for a destination, if it has one.
    func webURL(forDestination destination: String) -> String?
    /// The Shelley web agent's URL for a destination, if the provider serves one.
    func shelleyURL(forDestination destination: String) -> String?
    /// The command that asks a VM its current name (reflection), if the provider
    /// supports renaming. nil otherwise.
    var reflectionNameCommand: String? { get }
    /// Parse the reflection endpoint's reply into a name, if any.
    func parseReflectedName(_ output: String) -> String?

    // MARK: - Transport

    /// The command transport bound to a destination.
    func transport(forDestination destination: String) -> RemoteTransport

    /// A shell fragment that injects `environment` onto the VM so every process
    /// sees it, for providers that can't set host env at create time. exe.dev
    /// sets env via `new --env`, so the default is "" and the bootstrap doesn't
    /// inject; sprites.dev has no host-env API, so it writes a profile the shell
    /// sources (see `SpritesProvider`).
    func hostEnvironmentSetup(_ environment: [EnvVar]) -> String { "" }
}
