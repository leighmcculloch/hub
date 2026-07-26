import Foundation

/// Pure helpers for turning app configuration into the command run on a VM.
///
/// Kept free of UI/Combine imports so they stay compilable — and testable — off
/// macOS.
enum Bootstrap {
    /// Seeded to `~/.claude.json` on a fresh VM. Claude Code keeps onboarding
    /// state here rather than in `settings.json`, so this is what actually
    /// suppresses the first-run flow.
    static let claudeState = """
    {
      "hasCompletedOnboarding": true
    }
    """

    /// Turn a user-supplied session name into a valid exe.dev VM name, falling
    /// back to a generated one when empty.
    ///
    /// exe.dev rejects anything that isn't "5-52 characters: start with a
    /// lowercase letter, then lowercase letters or digits, with optional single
    /// hyphen separators" — so this must also collapse hyphen runs, strip
    /// leading/trailing hyphens, prefix a name starting with a digit, and pad a
    /// name that is too short.
    static func vmName(from sessionName: String) -> String {
        var name = String(sessionName.lowercased().map {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) ? $0 : "-"
        })
        while name.contains("--") {
            name = name.replacingOccurrences(of: "--", with: "-")
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        // Must begin with a lowercase letter.
        if name.first.map({ ("a"..."z").contains($0) }) != true {
            name = name.isEmpty ? "" : "vm-" + name
        }

        // Long names are truncated; truncation can expose a trailing hyphen.
        if name.count > 52 {
            name = String(name.prefix(52))
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }

        // Minimum length is 5; pad (or generate) with a random suffix.
        if name.count < 5 {
            let suffix = UUID().uuidString.prefix(6).lowercased()
            name = name.isEmpty ? "vm-\(suffix)" : "\(name)-\(suffix)"
        }
        return name
    }

    /// Build the remote command run over SSH: decode and execute a bootstrap
    /// script (write `~/.claude/settings.json`, run the setup script, then a
    /// `git clone` per repo through the exe.dev GitHub proxy), then drop into an
    /// interactive login shell.
    ///
    /// The script is base64-encoded so arbitrary multi-line user content (setup
    /// script, settings JSON) survives the trip through SSH argument and
    /// remote-shell parsing.
    static func command(
        setupScript: String,
        claudeSettings: String,
        repos: [String],
        startCommand: String = ""
    ) -> String {
        let encoded = Data(script(setupScript: setupScript,
                                  claudeSettings: claudeSettings,
                                  repos: repos).utf8).base64EncodedString()
        return "printf %s '\(encoded)' | base64 -d > /tmp/exe-bootstrap.sh"
            + " && chmod +x /tmp/exe-bootstrap.sh && /tmp/exe-bootstrap.sh;"
            + " \(loginShellCommand(startCommand: startCommand))"
    }

    /// tmux session every VM session attaches to.
    static let tmuxSession = "exe"

    /// The final command that hands the TTY to the user.
    ///
    /// Always goes through tmux: `-A` attaches to the existing session or
    /// creates one, so a dropped SSH connection reattaches with work intact
    /// rather than losing it. The trailing command runs *only* when the session
    /// is created, never on attach, so reconnecting never stacks a second copy.
    ///
    /// It runs under a login shell so the user's profile — and therefore `PATH`
    /// — is loaded first, and is followed by another login shell so detaching
    /// (or tmux being unavailable) leaves you at a prompt instead of closing the
    /// session. `${SHELL}` stays inside single quotes so it is expanded
    /// remotely, not here.
    static func loginShellCommand(startCommand: String) -> String {
        let trimmed = startCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        var tmux = "tmux new-session -A -s \(tmuxSession)"
        if !trimmed.isEmpty {
            // Quoted as one argument so multi-word commands aren't parsed as
            // tmux's own flags.
            tmux += " " + shellQuote(trimmed)
        }
        return "exec ${SHELL:-bash} -l -c " + shellQuote("\(tmux); exec ${SHELL:-bash} -l")
    }

    /// Single-quote for a POSIX shell, escaping embedded single quotes.
    static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The script body that gets base64-encoded into `command`.
    static func script(setupScript: String, claudeSettings: String, repos: [String]) -> String {
        var script = "#!/usr/bin/env bash\n"

        // Seed Claude Code's settings, but never clobber one the user already
        // customized on the VM.
        if !claudeSettings.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let encodedSettings = Data(claudeSettings.utf8).base64EncodedString()
            // Onboarding state lives in ~/.claude.json (Claude Code's state
            // file), not in settings.json, so seed it there as well or a fresh
            // VM still shows the onboarding flow.
            let encodedState = Data(Self.claudeState.utf8).base64EncodedString()
            script += """
            mkdir -p "$HOME/.claude"
            if [ ! -f "$HOME/.claude/settings.json" ]; then
              printf %s '\(encodedSettings)' | base64 -d > "$HOME/.claude/settings.json"
            fi
            if [ ! -f "$HOME/.claude.json" ]; then
              printf %s '\(encodedState)' | base64 -d > "$HOME/.claude.json"
            fi

            """
        }

        // Every session runs inside tmux, so make sure it's there. Failure is
        // tolerated: the login-shell fallback still gives a usable terminal.
        script += """
        if ! command -v tmux >/dev/null 2>&1; then
          sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y -qq tmux >/dev/null 2>&1 || true
        fi

        """

        script += setupScript
        script += "\n"
        for repo in repos {
            script += "git clone https://github.int.exe.xyz/\(repo).git || true\n"
        }

        // Mark every directory in the home dir as trusted, so Claude Code
        // doesn't prompt per folder. Runs after the clones so the freshly
        // cloned repos are included, and merges into any existing
        // ~/.claude.json rather than replacing real state.
        script += trustHomeDirectories
        return script
    }

    /// Merges `hasTrustDialogAccepted` for `$HOME` and each visible directory
    /// under it into `~/.claude.json`. Tolerates a missing or malformed file,
    /// and is a no-op if python3 isn't present.
    static let trustHomeDirectories = """

    python3 - <<'PYEOF' || true
    import json, os
    home = os.path.expanduser("~")
    path = os.path.join(home, ".claude.json")
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        data = {}
    if not isinstance(data, dict):
        data = {}
    data.setdefault("hasCompletedOnboarding", True)
    projects = data.setdefault("projects", {})
    if not isinstance(projects, dict):
        projects = data["projects"] = {}
    targets = [home]
    for name in sorted(os.listdir(home)):
        full = os.path.join(home, name)
        if not name.startswith(".") and os.path.isdir(full):
            targets.append(full)
    for target in targets:
        entry = projects.setdefault(target, {})
        if isinstance(entry, dict):
            entry["hasTrustDialogAccepted"] = True
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    PYEOF

    """
}
