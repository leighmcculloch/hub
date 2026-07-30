import Foundation

struct GitHubRepo: Identifiable, Hashable, Codable {
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
    ///
    /// Trimmed, because this is written straight into `git config user.name` on
    /// the VM — a profile name that is blank or only spaces would otherwise
    /// author every commit as nothing.
    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? login : trimmed
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
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    return Result(repos: sorted(collected), error: apiError(status: status, body: data))
                }

                let batch = try JSONDecoder().decode([RepoDTO].self, from: data)
                collected.append(contentsOf: batch.map { GitHubRepo(fullName: $0.full_name, isPrivate: $0.isPrivate) })
                if batch.count < 100 { break }
                page += 1
            }
            let sorted = sorted(collected)
            // Persist for the next open: the picker can render immediately from
            // the cache and refresh from the network in the background.
            RepoCache.write(sorted)
            return Result(repos: sorted, error: nil)
        } catch {
            return Result(repos: [], error: "Failed to list repos: \(error.localizedDescription)")
        }
    }

    /// Ordered the way the picker is read, not the way bytes compare.
    ///
    /// A plain `<` puts every capitalised name ahead of every lowercase one, so
    /// `ZZZ/a` landed above `aaa/b` and the list looked arbitrary to scan.
    /// Ties are broken by the exact name so the order is still total.
    static func sorted(_ repos: [GitHubRepo]) -> [GitHubRepo] {
        repos.sorted { left, right in
            let comparison = left.fullName.localizedCaseInsensitiveCompare(right.fullName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return left.fullName < right.fullName
        }
    }

    /// One readable line. GitHub answers with JSON normally but an HTML page
    /// from an intermediary when things go wrong, and this lands in a label.
    static func apiError(status: Int, body: Data) -> String {
        "GitHub API error (HTTP \(status)): \(MessageText.condense(body))"
            + MessageText.tokenHint(for: status, setting: "GITHUB_TOKEN, or run `gh auth login`")
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
