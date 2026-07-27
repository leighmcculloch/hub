import Foundation

/// How a repo path from the VM's home directory is shown in the sidebar.
enum RepoLabel {
    /// The path segment Claude puts its worktrees under, relative to a repo.
    static let worktreeMarker = "/.claude/worktrees/"

    /// A short label for `repo`.
    ///
    /// A Claude worktree lives at `<repo>/.claude/worktrees/<branch>`, which in
    /// a narrow sidebar is mostly boilerplate and pushes the part that actually
    /// identifies it off the end. Shown as `<repo> › <branch>` instead. Anything
    /// else is already short enough to show as-is.
    static func short(_ repo: String) -> String {
        guard let range = repo.range(of: worktreeMarker) else { return repo }
        let owner = String(repo[repo.startIndex..<range.lowerBound])
        let branch = String(repo[range.upperBound...])
        // A trailing marker with nothing after it isn't a worktree path.
        guard !branch.isEmpty, !owner.isEmpty else { return repo }
        return "\(owner) › \(branch)"
    }

    /// Spoken form of `short`, for accessibility — the chevron doesn't read.
    static func spoken(_ repo: String) -> String {
        short(repo).replacingOccurrences(of: " › ", with: " worktree ")
    }

    static func isWorktree(_ repo: String) -> Bool {
        short(repo) != repo
    }
}
