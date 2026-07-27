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
        if let failure = Self.failure(status: http.statusCode, body: data) {
            throw failure
        }
        return data
    }

    /// The error a response represents, or nil if it succeeded.
    ///
    /// Separate from the request so the message-building — the part a user
    /// actually reads when something breaks — can be exercised directly.
    static func failure(status: Int, body: Data) -> ExeError? {
        // Error responses are `{"error":"..."}` regardless of status code, so
        // this is checked before the status.
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = object["error"] as? String {
            return ExeError(message: "exe.dev (HTTP \(status)): \(condense(error))\(hint(for: status))")
        }
        guard !(200..<300).contains(status) else { return nil }
        return ExeError(
            message: "exe.dev HTTP \(status): \(MessageText.condense(body))\(hint(for: status))")
    }

    private static func hint(for status: Int) -> String {
        MessageText.tokenHint(for: status, setting: "your API token in Settings (⌘,) or EXE_DEV_TOKEN")
    }

    static func condense(_ body: String) -> String {
        MessageText.condense(body)
    }

    /// Run a command and decode its JSON output.
    func runJSON<T: Decodable>(_ command: String, as type: T.Type) async throws -> T {
        let data = try await run(command)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ExeError(
                message: "Unexpected exe.dev response for `\(command)`: \(MessageText.condense(data))")
        }
    }
}
