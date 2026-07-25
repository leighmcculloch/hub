import Combine
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

    init() {}

    /// Decoded field-by-field with `decodeIfPresent` so a config file written by
    /// an older build (missing newer keys) still loads. The synthesized
    /// initializer would throw on a missing key and discard the whole file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exeToken = try container.decodeIfPresent(String.self, forKey: .exeToken) ?? ""
        setupScript = try container.decodeIfPresent(String.self, forKey: .setupScript)
            ?? "echo insert setup script here"
        environment = try container.decodeIfPresent([EnvVar].self, forKey: .environment) ?? []
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName) ?? "Menlo"
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        claudeSettings = try container.decodeIfPresent(String.self, forKey: .claudeSettings)
            ?? AppConfigData.defaultClaudeSettings
    }
}

/// Loads and persists `AppConfigData`. A single shared instance is observed by
/// both the main window and the Settings scene.
final class AppConfig: ObservableObject {
    static let shared = AppConfig()

    @Published var data: AppConfigData {
        didSet { save() }
    }

    private let fileURL: URL

    private init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExeDesktopApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("config.json")

        if let bytes = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppConfigData.self, from: bytes) {
            data = decoded
        } else {
            data = AppConfigData()
        }
    }

    /// Clamped so ⌘+/⌘- can't drive the terminal to an unusable size.
    func adjustFontSize(by delta: Double) {
        data.fontSize = min(max(data.fontSize + delta, 8), 32)
    }

    /// The token to use: the configured one, or the environment fallback.
    var effectiveToken: String {
        if !data.exeToken.isEmpty { return data.exeToken }
        return ProcessInfo.processInfo.environment["EXE_DEV_TOKEN"] ?? ""
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let bytes = try? encoder.encode(data) else { return }
        try? bytes.write(to: fileURL, options: [.atomic])
    }
}
