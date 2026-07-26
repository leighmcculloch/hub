import Foundation

struct GitHubRepo: Identifiable, Hashable {
    var id: String { fullName }
    let fullName: String
    let isPrivate: Bool
}

/// The authenticated GitHub user, used to seed `git config` on a new VM so
/// commits are attributed correctly without the user configuring anything.
struct GitHubUser: Equatable {
    let login: String
    let id: Int
    let name: String?

    /// Commit author name: the profile name when set, else the login.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return login
    }

    /// GitHub's private commit address for this account, which keeps the real
    /// email out of commits while still linking them to the profile.
    var noreplyEmail: String { "\(id)+\(login)@users.noreply.github.com" }
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

    /// The authenticated user, or nil when no token is available.
    static func currentUser() async -> GitHubUser? {
        guard let token = await discoverToken() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ExeDesktopApp", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let dto = try? JSONDecoder().decode(UserDTO.self, from: data)
        else { return nil }
        return GitHubUser(login: dto.login, id: dto.id, name: dto.name)
    }

    private struct UserDTO: Decodable {
        let login: String
        let id: Int
        let name: String?
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
