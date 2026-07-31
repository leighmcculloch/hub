import Foundation

/// A VM-backed tab to restore on the next launch.
struct PersistedSession: Codable, Equatable {
    var destination: String
    var title: String
    var vmName: String?
    /// Which provider the tab ran on, so restore reconstructs the right
    /// transport. Defaults to exe.dev for files written before this existed.
    var provider: VMProviderID = .exe

    init(destination: String, title: String, vmName: String?, provider: VMProviderID = .exe) {
        self.destination = destination
        self.title = title
        self.vmName = vmName
        self.provider = provider
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        destination = try container.decode(String.self, forKey: .destination)
        title = try container.decode(String.self, forKey: .title)
        vmName = try container.decodeIfPresent(String.self, forKey: .vmName)
        // A file written before providers existed has no `provider` key; it's an
        // exe.dev session.
        provider = try container.decodeIfPresent(VMProviderID.self, forKey: .provider) ?? .exe
    }
}

/// The workspace as written to disk: which tabs were open, and which was
/// active.
struct PersistedWorkspace: Codable, Equatable {
    var sessions: [PersistedSession] = []
    /// SSH destination of the tab that was in front, if any.
    var selected: String?
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

    /// The previously open tabs. A missing or unreadable file just means none.
    func load() -> PersistedWorkspace {
        guard let bytes = try? Data(contentsOf: fileURL) else { return PersistedWorkspace() }
        if let workspace = try? JSONDecoder().decode(PersistedWorkspace.self, from: bytes) {
            return workspace
        }
        // Files written before the selection was recorded hold a bare array.
        // Reading them is what stops an upgrade from emptying the workspace.
        if let sessions = try? JSONDecoder().decode([PersistedSession].self, from: bytes) {
            return PersistedWorkspace(sessions: sessions)
        }
        return PersistedWorkspace()
    }

    func save(_ workspace: PersistedWorkspace) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let bytes = try? encoder.encode(workspace) else { return }
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

    /// Which tab to put in front on restore.
    ///
    /// The one that was active, when it came back — landing on the first tab
    /// after a restart loses your place for no reason. Falls back to the first
    /// when the active tab's VM is gone, or when the file predates this being
    /// recorded at all.
    static func restorableSelection(
        _ selected: String?,
        in sessions: [PersistedSession]
    ) -> String? {
        guard let selected, sessions.contains(where: { $0.destination == selected })
        else { return sessions.first?.destination }
        return selected
    }
}
