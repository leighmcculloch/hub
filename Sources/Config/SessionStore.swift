import Foundation

/// A VM-backed tab to restore on the next launch.
struct PersistedSession: Codable, Equatable {
    var destination: String
    var title: String
    var vmName: String?
}

/// Records which VM tabs were open so quitting doesn't lose the workspace.
///
/// Kept separate from `AppConfig`: this is session state the app manages, not
/// settings the user edits. The file URL is injectable so the behaviour can be
/// tested without touching the real Application Support directory.
final class SessionStore {
    static let shared = SessionStore()

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExeDesktopApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("sessions.json")
    }

    /// Previously open tabs. A missing or unreadable file just means none.
    func load() -> [PersistedSession] {
        guard let bytes = try? Data(contentsOf: fileURL),
              let sessions = try? JSONDecoder().decode([PersistedSession].self, from: bytes)
        else { return [] }
        return sessions
    }

    func save(_ sessions: [PersistedSession]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let bytes = try? encoder.encode(sessions) else { return }
        try? bytes.write(to: fileURL, options: [.atomic])
    }

    /// Which persisted tabs to restore, given the VMs that currently exist.
    ///
    /// Tabs whose VM is gone are dropped so a deleted VM doesn't come back as a
    /// dead tab. But if the VM list is empty — no token, or the lookup failed —
    /// the persisted list is trusted rather than silently wiping the workspace
    /// over a network blip.
    static func restorable(
        persisted: [PersistedSession],
        knownDestinations: Set<String>
    ) -> [PersistedSession] {
        guard !knownDestinations.isEmpty else { return persisted }
        return persisted.filter { knownDestinations.contains($0.destination) }
    }
}
