import Foundation

/// Pure helpers for turning app configuration into the command run on a VM.
///
/// Kept free of UI/Combine imports so they stay compilable — and testable — off
/// macOS.
enum Bootstrap {
    /// Turn a user-supplied session name into a valid exe.dev VM name, falling
    /// back to a generated one when empty. VM names are lowercase alphanumeric
    /// with dashes.
    static func vmName(from sessionName: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let slug = String(sessionName.lowercased().map { allowed.contains($0) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !slug.isEmpty else {
            return "tab-" + UUID().uuidString.prefix(8).lowercased()
        }
        return String(slug.prefix(40))
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

    /// The final command that hands the TTY to the user.
    ///
    /// With no start command this is just a login shell. With one, the login
    /// shell runs it (so the user's profile — and therefore `PATH` — is loaded
    /// first) and then execs another login shell, so quitting the command leaves
    /// you at a prompt instead of closing the session. `${SHELL}` stays inside
    /// single quotes so it is expanded remotely, not here.
    static func loginShellCommand(startCommand: String) -> String {
        let trimmed = startCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "exec ${SHELL:-bash} -l" }
        return "exec ${SHELL:-bash} -l -c " + shellQuote("\(trimmed); exec ${SHELL:-bash} -l")
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
            script += """
            mkdir -p "$HOME/.claude"
            if [ ! -f "$HOME/.claude/settings.json" ]; then
              printf %s '\(encodedSettings)' | base64 -d > "$HOME/.claude/settings.json"
            fi

            """
        }

        script += setupScript
        script += "\n"
        for repo in repos {
            script += "git clone https://github.int.exe.xyz/\(repo).git || true\n"
        }
        return script
    }
}
