import Foundation

/// Persisted application configuration, stored as JSON in Application Support.
struct AppConfigData: Codable {
    /// exe.dev HTTPS API bearer token. Kept out of source; entered in Settings
    /// or supplied via the `EXE_DEV_TOKEN` environment variable.
    var exeToken: String = ""

    /// A `rename`-only exe.dev token, handed to VMs that name themselves from
    /// the agent's first prompt (see `AutoName`). Minted on demand rather than
    /// entered, and cached here so one key on the account serves every session.
    var renameToken: String = ""

    /// When it was minted, so it can be replaced before its expiry passes and
    /// takes auto-naming down with it.
    var renameTokenMinted: Date?

    /// The ways a session can be run — setup script, start command, and its own
    /// environment variables. One is chosen when a session is created.
    var environments: [SessionEnvironment] = SessionEnvironment.defaults

    /// The environment new sessions use, remembered between launches. Nil — or
    /// an id that no longer exists — means the first one.
    var selectedEnvironmentID: UUID?

    /// The exe.dev gateway model new sessions are pointed at. Nil is "Custom":
    /// nothing is set, and whatever the VM is already configured with stands.
    var model: GatewayModel?

    /// Environment variables set on each new VM host (passed to `new --env`), so
    /// they're present for every process on the VM, not just our shell. These
    /// apply whichever environment the session runs.
    var globalEnvironment: [EnvVar] = []

    /// Terminal font.
    var fontName: String = "Menlo"
    var fontSize: Double = 13

    /// Written to `~/.claude/settings.json` on each new VM during bootstrap.
    /// Editable so the exact keys can be adjusted without a code change.
    var claudeSettings: String = AppConfigData.defaultClaudeSettings

    static let defaultClaudeSettings = """
    {
      "theme": "dark",
      "permissions": {
        "defaultMode": "bypassPermissions"
      },
      "attribution": {
        "commit": "",
        "pr": "🤖 Generated with [Claude Code](https://claude.com/claude-code)",
        "sessionUrl": true
      },
      "remoteControlAtStartup": true,
      "hasCompletedOnboarding": true,
      "disableWorkflows": false,
      "prefersReducedMotion": true,
      "skipDangerousModePermissionPrompt": true
    }
    """

    /// Sizes the terminal font is allowed to take, shared with ⌘+/⌘- so the two
    /// can't disagree about what is usable.
    static let fontSizeRange = 8.0...32.0

    init() {}

    /// The environment new sessions run. Falls back to the first one, so a
    /// stale or missing selection still yields something runnable.
    var selectedEnvironment: SessionEnvironment {
        environments.first { $0.id == selectedEnvironmentID }
            ?? environments.first
            ?? SessionEnvironment()
    }

    /// Decoded field by field so a config file written by an older build — or
    /// hand-edited, which the format invites — still loads. The synthesized
    /// initializer throws on the first missing key and discards the whole file.
    ///
    /// Each field also falls back independently when its value is present but
    /// the wrong type. One bad entry should cost that entry, not the token and
    /// environments alongside it.
    ///
    /// Fallbacks come from a default-constructed instance rather than repeating
    /// the literals: written out twice, the two copies drift.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfigData()

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        exeToken = value(.exeToken, defaults.exeToken)
        renameToken = value(.renameToken, defaults.renameToken)
        renameTokenMinted = value(.renameTokenMinted, defaults.renameTokenMinted)
        // An empty list would leave nothing to select or edit, so it's treated
        // as absent rather than honoured.
        let stored = value(.environments, defaults.environments)
        environments = stored.isEmpty ? defaults.environments : stored
        selectedEnvironmentID = value(.selectedEnvironmentID, defaults.selectedEnvironmentID)
        model = value(.model, defaults.model)
        globalEnvironment = value(.globalEnvironment, defaults.globalEnvironment)
        fontName = value(.fontName, defaults.fontName)
        claudeSettings = value(.claudeSettings, defaults.claudeSettings)

        migrateLegacyKeys(
            from: decoder,
            hasEnvironments: container.contains(.environments),
            hasGlobalEnvironment: container.contains(.globalEnvironment))

        // Clamped, not just defaulted: a hand-edited 0 or 400 would otherwise
        // give a terminal that can't be read.
        let size = value(.fontSize, defaults.fontSize)
        fontSize = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }

    /// Carry a file written before environments existed, when the app had one
    /// setup script, one start command, and one list of variables. They become
    /// the first environment, so an upgrade doesn't lose a setup script someone
    /// wrote — and the variables stay global, which is what they were.
    ///
    /// A second `CodingKeys` enum because these keys have no property left to
    /// hang off; adding cases to the real one would break the synthesized
    /// encoder.
    private mutating func migrateLegacyKeys(
        from decoder: Decoder, hasEnvironments: Bool, hasGlobalEnvironment: Bool
    ) {
        enum LegacyKeys: String, CodingKey {
            case setupScript
            case startCommand
            case environment
        }
        guard let legacy = try? decoder.container(keyedBy: LegacyKeys.self) else { return }

        func value<T: Decodable>(_ key: LegacyKeys, _ fallback: T) -> T {
            ((try? legacy.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        if !hasEnvironments {
            let setupScript = value(.setupScript, "")
            let startCommand = value(.startCommand, "")
            // The first environment is also the one a file with no selection
            // resolves to, so nothing else has to be set.
            if !setupScript.isEmpty || !startCommand.isEmpty {
                environments[0].setupScript = setupScript
                environments[0].startCommand = startCommand
            }
        }

        // `environment` was these variables before the per-environment lists
        // arrived and forced the clearer name.
        if !hasGlobalEnvironment {
            globalEnvironment = value(.environment, globalEnvironment)
        }
    }
}
