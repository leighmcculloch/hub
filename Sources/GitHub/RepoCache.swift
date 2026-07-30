import Foundation

/// On-disk cache of the last fetched GitHub repo list, so the new-tab picker
/// can show something immediately and refresh in the background instead of
/// staring at a spinner until the network answers.
///
/// Stored separately from `config.json` — repos are a cache of account data,
/// not settings — in the same Application Support directory. A corrupt or
/// partial file is treated as a miss; the next fetch rewrites it.
enum RepoCache {
    /// Where the cache lives. A `var` only so tests can point it at a temp
    /// file; production code never reassigns it.
    private(set) static var fileURL: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExeDesktopApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("repos-cache.json")
    }()

    /// The last fetched list, or nil when nothing usable is cached.
    static func read() -> [GitHubRepo]? {
        guard let bytes = try? Data(contentsOf: fileURL),
              let repos = try? JSONDecoder().decode([GitHubRepo].self, from: bytes)
        else { return nil }
        return repos
    }

    /// Records a freshly fetched list. Best-effort: a write failure just means
    /// the next open shows a spinner again, so it isn't surfaced.
    static func write(_ repos: [GitHubRepo]) {
        guard let bytes = try? JSONEncoder().encode(repos) else { return }
        try? bytes.write(to: fileURL, options: [.atomic])
    }
}
