import Foundation

/// One named way to run a session: the setup script, the command started inside
/// tmux, and environment variables set on the VM host.
///
/// A session picks one when it is created, so a Claude Code VM and a Codex VM
/// can differ without editing Settings in between.
struct SessionEnvironment: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = ""

    /// Run over SSH as the first command on the VM, before the repos are cloned.
    var setupScript: String = ""

    /// Run inside tmux when the session is first created, e.g. `claude`.
    var startCommand: String = ""

    /// Set on the VM host on top of the global variables.
    var environment: [EnvVar] = []

    init(
        id: UUID = UUID(),
        name: String = "",
        setupScript: String = "",
        startCommand: String = "",
        environment: [EnvVar] = []
    ) {
        self.id = id
        self.name = name
        self.setupScript = setupScript
        self.startCommand = startCommand
        self.environment = environment
    }

    /// Lenient like `EnvVar`: the config file invites hand-editing, so a missing
    /// or mistyped field costs that field rather than the whole environment.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        id = value(.id, UUID())
        name = value(.name, "")
        setupScript = value(.setupScript, "")
        startCommand = value(.startCommand, "")
        environment = value(.environment, [])
    }

    /// What a fresh install starts with: the two harnesses this app is used
    /// with. Anything else is added in Settings.
    ///
    /// The ids are fixed rather than generated, so a config file that records
    /// only which environment is selected still points at the same one after a
    /// restart.
    static let defaults: [SessionEnvironment] = [
        SessionEnvironment(
            id: UUID(uuidString: "8F1D4F4E-1D2B-4C1B-9E3A-000000000001")!,
            name: "Claude Code",
            startCommand: "claude",
            // Present but blank on purpose: it's the variable to paste a token
            // into, and an empty row is the prompt to do so.
            environment: [EnvVar(key: "CLAUDE_CODE_OAUTH_TOKEN")]
        ),
        SessionEnvironment(
            id: UUID(uuidString: "8F1D4F4E-1D2B-4C1B-9E3A-000000000002")!,
            name: "Codex",
            startCommand: "codex"
        ),
    ]
}
