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
            .appendingPathComponent("TerminalWorkspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("config.json")

        if let bytes = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppConfigData.self, from: bytes) {
            data = decoded
        } else {
            data = AppConfigData()
        }
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
