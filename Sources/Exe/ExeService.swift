import Foundation

/// One integration as returned by `integrations list --json`.
struct ExeIntegration: Decodable {
    let name: String
    let type: String
    let attachments: [String]?
    let config: Config?

    struct Config: Decodable {
        let repositories: [String]?
        let act_as_user: Bool?
    }

    /// The first `tag:<name>` this integration is attached to, if any.
    var attachedTag: String? {
        attachments?
            .compactMap { $0.hasPrefix("tag:") ? String($0.dropFirst("tag:".count)) : nil }
            .first
    }
}

/// A VM as returned by `new --json` / `ls --json`. Fields are optional so we
/// tolerate shape differences between commands.
struct ExeVM: Decodable, Identifiable {
    let vm_name: String?
    let ssh_dest: String?
    let https_url: String?
    let status: String?
    let region: String?
    let tags: [String]?

    // Must be stable across reads: a fresh UUID here would give SwiftUI a new
    // identity on every render and churn the list.
    var id: String { vm_name ?? ssh_dest ?? "unknown" }
}

/// `ls --json` wraps its results in a `vms` array.
struct ExeVMList: Decodable {
    let vms: [ExeVM]
}

/// Higher-level exe.dev operations composed from CLI commands.
final class ExeService {
    let client: ExeClient

    init(client: ExeClient) {
        self.client = client
    }

    func listIntegrations() async throws -> [ExeIntegration] {
        try await client.runJSON("integrations list --json", as: [ExeIntegration].self)
    }

    /// Existing VMs on the account, so a closed session can be reopened.
    func listVMs() async throws -> [ExeVM] {
        try await client.runJSON("ls --json", as: ExeVMList.self).vms
    }

    /// Destroy a VM and its disk. Irreversible.
    func deleteVM(name: String) async throws {
        try await client.run("rm \(name)")
    }

    /// Mint the token a VM renames itself with — scoped to `rename` alone, so
    /// it can sit on a machine an agent runs unattended on. See `AutoName`.
    ///
    /// Throws when the account's own token isn't allowed to mint one, which is
    /// the common case until `ssh-key generate-api-key` is added to its `cmds`.
    func generateRenameToken() async throws -> String {
        let data = try await client.run(AutoName.mintTokenCommand)
        guard let token = Self.apiKey(from: data) else {
            throw ExeError(message: "No API key in exe.dev's reply: \(MessageText.condense(data))")
        }
        return token
    }

    /// The token out of `ssh-key generate-api-key --json`.
    ///
    /// Found by shape rather than by key name: exe.dev tokens are `exe0.`/`exe1.`
    /// strings, and that is the one thing about this response worth relying on —
    /// a renamed field would otherwise turn auto-naming off silently.
    static func apiKey(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return token(in: root)
    }

    private static func token(in value: Any) -> String? {
        switch value {
        case let text as String:
            return text.hasPrefix("exe0.") || text.hasPrefix("exe1.") ? text : nil
        case let list as [Any]:
            return list.compactMap(token(in:)).first
        case let object as [String: Any]:
            // Sorted so a response with two token-shaped values resolves the
            // same way every time rather than on dictionary order.
            return object.sorted { $0.key < $1.key }.compactMap { token(in: $0.value) }.first
        default:
            return nil
        }
    }

    /// Ensure a GitHub integration exists for `repo` ("owner/name") and return
    /// the tag that binds it to a VM, creating the integration (acting as the
    /// user) if it doesn't already exist.
    func ensureGithubIntegration(repo: String, existing: [ExeIntegration]) async throws -> String {
        let slug = Self.slug(repo)

        if let match = existing.first(where: {
            $0.type == "github" && ($0.config?.repositories?.contains(repo) ?? false)
        }) {
            if let tag = match.attachedTag { return tag }
            // Integration exists but isn't tag-attached; attach a tag we can bind.
            try await client.run("integrations attach \(match.name) tag:\(slug)")
            return slug
        }

        try await client.run(
            "integrations add github --name \(slug) --repository \(repo) --act-as-user --attach tag:\(slug)"
        )
        return slug
    }

    /// Create a VM with the given tags (so tag-attached integrations bind to it)
    /// and environment variables set on the host.
    func createVM(name: String, tags: [String], environment: [EnvVar] = []) async throws -> ExeVM {
        var command = "new --name \(name) --json"
        if !tags.isEmpty {
            command += " --tag \(tags.joined(separator: ","))"
        }
        for variable in environment where !variable.key.isEmpty {
            command += " --env \(Self.quote("\(variable.key)=\(variable.value)"))"
        }
        return try await client.runJSON(command, as: ExeVM.self)
    }

    /// Single-quote an argument for the exe.dev command parser, so values with
    /// spaces or shell metacharacters survive intact.
    static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Slug used for integration name and tag, e.g. "owner/Repo.Name" ->
    /// "owner-repo-name".
    ///
    /// exe.dev requires tag names to match `^[a-z][a-z0-9_-]*$`, so a repo whose
    /// owner starts with a digit (e.g. `4d63/x`) must be prefixed rather than
    /// passed through.
    static func slug(_ repo: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        var slug = String(repo.lowercased().map { allowed.contains($0) ? $0 : "-" })
        if slug.first.map(Self.isLowercaseLetter) != true {
            slug = "r-" + slug
        }
        return slug
    }

    private static func isLowercaseLetter(_ character: Character) -> Bool {
        ("a"..."z").contains(character)
    }
}
