import Foundation

/// Persisted application configuration, stored as JSON in Application Support.
struct AppConfigData: Codable {
    /// exe.dev HTTPS API bearer token. Kept out of source; entered in Settings
    /// or supplied via the `EXE_DEV_TOKEN` environment variable.
    var exeToken: String = ""

    /// Script run as the first command over SSH on each new VM tab, before the
    /// repos are cloned. User-editable in Settings.
    var setupScript: String = "echo insert setup script here"

    /// Environment variables set on each new VM host (passed to `new --env`), so
    /// they're present for every process on the VM, not just our shell.
    var environment: [EnvVar] = []

    /// Terminal font.
    var fontName: String = "Menlo"
    var fontSize: Double = 13

    /// Command run in the login shell after connecting, e.g. `claude`. Empty
    /// means just drop into the shell. When it exits you're left at a shell
    /// rather than losing the session.
    var startCommand: String = ""

    /// Written to `~/.claude/settings.json` on each new VM during bootstrap.
    /// Editable so the exact keys can be adjusted without a code change.
    var claudeSettings: String = AppConfigData.defaultClaudeSettings

    static let defaultClaudeSettings = """
    {
      "theme": "dark",
      "permissions": {
        "defaultMode": "auto"
      },
      "attribution": {
        "commit": "",
        "pr": "🤖 Generated with [Claude Code](https://claude.com/claude-code)",
        "sessionUrl": true
      },
      "remoteControlAtStartup": true,
      "hasCompletedOnboarding": true,
      "disableWorkflows": false,
      "prefersReducedMotion": true
    }
    """

    /// Sizes the terminal font is allowed to take, shared with ⌘+/⌘- so the two
    /// can't disagree about what is usable.
    static let fontSizeRange = 8.0...32.0

    init() {}

    /// Decoded field by field so a config file written by an older build — or
    /// hand-edited, which the format invites — still loads. The synthesized
    /// initializer throws on the first missing key and discards the whole file.
    ///
    /// Each field also falls back independently when its value is present but
    /// the wrong type. One bad entry should cost that entry, not the token and
    /// setup script alongside it.
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
        setupScript = value(.setupScript, defaults.setupScript)
        environment = value(.environment, defaults.environment)
        fontName = value(.fontName, defaults.fontName)
        startCommand = value(.startCommand, defaults.startCommand)
        claudeSettings = value(.claudeSettings, defaults.claudeSettings)

        // Clamped, not just defaulted: a hand-edited 0 or 400 would otherwise
        // give a terminal that can't be read.
        let size = value(.fontSize, defaults.fontSize)
        fontSize = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }
}
