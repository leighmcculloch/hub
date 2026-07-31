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
        let range = AppConfigData.fontSizeRange
        data.fontSize = min(max(data.fontSize + delta, range.lowerBound), range.upperBound)
    }

    /// The token to use for the active provider: the configured one, or the
    /// environment fallback.
    var effectiveToken: String { effectiveToken(for: data.provider) }

    /// The token for a given provider: the configured one, or that provider's
    /// environment fallback. Per-provider so a sprites.dev session opened while
    /// exe.dev was active still authenticates with the sprites token.
    func effectiveToken(for provider: VMProviderID) -> String {
        switch provider {
        case .exe:
            if !data.exeToken.isEmpty { return data.exeToken }
            return ProcessInfo.processInfo.environment["EXE_DEV_TOKEN"] ?? ""
        case .sprites:
            if !data.spritesToken.isEmpty { return data.spritesToken }
            return ProcessInfo.processInfo.environment["SPRITE_TOKEN"] ?? ""
        }
    }

    /// The provider the app is configured to use.
    func makeProvider() -> VMProvider { makeProvider(for: data.provider) }

    /// A provider instance for an id. Used for the active provider and to
    /// reconstruct a stored session's provider on restore.
    func makeProvider(for id: VMProviderID) -> VMProvider {
        switch id {
        case .exe:
            return ExeProvider(tokenProvider: { AppConfig.shared.effectiveToken(for: .exe) })
        case .sprites:
            return SpritesProvider(tokenProvider: { AppConfig.shared.effectiveToken(for: .sprites) })
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let bytes = try? encoder.encode(data) else { return }
        try? bytes.write(to: fileURL, options: [.atomic])
    }
}
