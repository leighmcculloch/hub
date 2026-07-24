import Foundation

struct ExeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thin client for the exe.dev HTTPS API.
///
/// The entire API is "run a CLI command": POST the command string to
/// `https://exe.dev/exec` with a bearer token; the response body is the command
/// output (always JSON, equivalent to passing `--json`). Errors come back as
/// `{"error":"..."}`.
final class ExeClient {
    private let tokenProvider: () -> String
    private let endpoint = URL(string: "https://exe.dev/exec")!

    init(tokenProvider: @escaping () -> String) {
        self.tokenProvider = tokenProvider
    }

    /// Run a command and return the raw response body.
    @discardableResult
    func run(_ command: String) async throws -> Data {
        let token = tokenProvider()
        guard !token.isEmpty else {
            throw ExeError(message: "No exe.dev API token configured. Add one in Settings (⌘,) or set EXE_DEV_TOKEN.")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(command.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ExeError(message: "No HTTP response from exe.dev")
        }

        // Error responses are `{"error":"..."}` regardless of status code.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? String {
            throw ExeError(message: "exe.dev (HTTP \(http.statusCode)): \(error)")
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ExeError(message: "exe.dev HTTP \(http.statusCode): \(body)")
        }
        return data
    }

    /// Run a command and decode its JSON output.
    func runJSON<T: Decodable>(_ command: String, as type: T.Type) async throws -> T {
        let data = try await run(command)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ExeError(message: "Unexpected exe.dev response for `\(command)`: \(body)")
        }
    }
}
