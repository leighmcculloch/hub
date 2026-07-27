import Combine
import Foundation

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
