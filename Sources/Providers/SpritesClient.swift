import Foundation

struct SpritesError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thin client for the sprites.dev REST API (`https://api.sprites.dev`).
///
/// Unlike exe.dev's "POST a command string to `/exec`", sprites.dev is a typed
/// REST API: `POST/GET/DELETE /v1/sprites/{name}`. Auth is a bearer token.
/// sprites.dev has no API to set host environment, so env vars are injected by
/// the bootstrap script instead (see `SpritesProvider.hostEnvironmentSetup`).
final class SpritesClient {
    private let tokenProvider: () -> String
    private let baseURL: URL

    init(tokenProvider: @escaping () -> String) {
        self.tokenProvider = tokenProvider
        // `SPRITES_API_URL` overrides the default endpoint, mirroring the CLI.
        let env = ProcessInfo.processInfo.environment
        var base = env["SPRITES_API_URL"] ?? "https://api.sprites.dev"
        // Strip a trailing slash so `base + "/v1/sprites"` doesn't double it;
        // built by concatenation so a query string on `path` survives intact.
        while base.hasSuffix("/") { base.removeLast() }
        self.baseURL = URL(string: base)!
    }

    // MARK: - Sprite lifecycle

    struct Sprite: Decodable {
        let id: String?
        let name: String
        let url: String?
        let status: String?
    }

    func create(name: String) async throws -> Sprite {
        try await request(.post, "/v1/sprites", body: ["name": name])
    }

    func get(name: String) async throws -> Sprite {
        try await request(.get, "/v1/sprites/\(name)")
    }

    func delete(name: String) async throws {
        try await requestEmpty(.delete, "/v1/sprites/\(name)")
    }

    /// All sprites in the org, paginated. The list endpoint returns a reduced
    /// shape (name only), so `listVMs` GETs each one for its URL and status.
    func listNames() async throws -> [String] {
        var names: [String] = []
        var token: String?
        repeat {
            var path = "/v1/sprites?max_results=50"
            if let token { path += "&continuation_token=\(token)" }
            let page: ListPage = try await request(.get, path)
            names.append(contentsOf: page.sprites.map(\.name))
            token = page.has_more ? page.next_continuation_token : nil
        } while token != nil
        return names
    }

    private struct ListPage: Decodable {
        let sprites: [Listed]
        let has_more: Bool
        let next_continuation_token: String?
        struct Listed: Decodable { let name: String }
    }

    // MARK: - HTTP

    private enum Method: String { case get = "GET", post = "POST", delete = "DELETE", patch = "PATCH" }

    private func request<T: Decodable>(_ method: Method, _ path: String, body: [String: Any]? = nil) async throws -> T {
        let (data, status) = try await send(method, path, body: body)
        guard (200..<300).contains(status) else {
            throw SpritesError(message: "sprites.dev (HTTP \(status)): \(MessageText.condense(data))"
                + MessageText.tokenHint(for: status, setting: "your API token in Settings (⌘,) or SPRITE_TOKEN"))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SpritesError(message: "Unexpected sprites.dev response: \(MessageText.condense(data))")
        }
    }

    private func requestEmpty(_ method: Method, _ path: String, body: [String: Any]? = nil) async throws {
        let (data, status) = try await send(method, path, body: body)
        guard (200..<300).contains(status) else {
            throw SpritesError(message: "sprites.dev (HTTP \(status)): \(MessageText.condense(data))"
                + MessageText.tokenHint(for: status, setting: "your API token in Settings (⌘,) or SPRITE_TOKEN"))
        }
    }

    private func send(_ method: Method, _ path: String, body: [String: Any]?) async throws -> (Data, Int) {
        let token = tokenProvider()
        guard !token.isEmpty else {
            throw SpritesError(message: "No sprites.dev API token configured. Add one in Settings (⌘,) or set SPRITE_TOKEN.")
        }

        var request = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        request.httpMethod = method.rawValue
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }
}
