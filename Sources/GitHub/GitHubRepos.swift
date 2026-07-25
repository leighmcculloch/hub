import Foundation

struct GitHubRepo: Identifiable, Hashable {
    var id: String { fullName }
    let fullName: String
    let isPrivate: Bool
}

/// Lists the GitHub repositories the current user can access, for the new-tab
/// repo picker.
///
/// GitHub auth is discovered locally: `GITHUB_TOKEN`/`GH_TOKEN`, else the `gh`
/// CLI's token. If none is found the picker still allows typing `owner/repo`
/// manually.
enum GitHubRepos {
    struct Result {
        var repos: [GitHubRepo]
        var error: String?
    }

    static func list() async -> Result {
        guard let token = await discoverToken() else {
            return Result(repos: [], error:
                "No GitHub token found. Run `gh auth login` or set GITHUB_TOKEN to list repos — or type owner/repo below.")
        }

        do {
            var collected: [GitHubRepo] = []
            var page = 1
            while page <= 10 {
                var components = URLComponents(string: "https://api.github.com/user/repos")!
                components.queryItems = [
                    .init(name: "per_page", value: "100"),
                    .init(name: "page", value: String(page)),
                    .init(name: "sort", value: "full_name"),
                    .init(name: "affiliation", value: "owner,collaborator,organization_member"),
                ]
                var request = URLRequest(url: components.url!)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("ExeDesktopApp", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    return Result(repos: collected, error: "GitHub API error: \(body)")
                }

                let batch = try JSONDecoder().decode([RepoDTO].self, from: data)
                collected.append(contentsOf: batch.map { GitHubRepo(fullName: $0.full_name, isPrivate: $0.isPrivate) })
                if batch.count < 100 { break }
                page += 1
            }
            return Result(repos: collected.sorted { $0.fullName < $1.fullName }, error: nil)
        } catch {
            return Result(repos: [], error: "Failed to list repos: \(error.localizedDescription)")
        }
    }

    private struct RepoDTO: Decodable {
        let full_name: String
        let isPrivate: Bool
        enum CodingKeys: String, CodingKey {
            case full_name
            case isPrivate = "private"
        }
    }

    private static func discoverToken() async -> String? {
        let env = ProcessInfo.processInfo.environment
        for key in ["GITHUB_TOKEN", "GH_TOKEN"] {
            if let value = env[key], !value.isEmpty { return value }
        }
        return await ghCLIToken()
    }

    /// `gh auth token`, if the GitHub CLI is installed and authenticated.
    private static func ghCLIToken() async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gh", "auth", "token"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }

            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = process.terminationStatus == 0 && !(token?.isEmpty ?? true)
            continuation.resume(returning: ok ? token : nil)
        }
    }
}
