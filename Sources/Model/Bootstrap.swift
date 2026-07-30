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
        if name.count > maxVMNameLength {
            name = String(name.prefix(maxVMNameLength))
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }

        // Minimum length is 5; pad (or generate) with a random suffix.
        if name.count < 5 {
            let suffix = UUID().uuidString.prefix(6).lowercased()
            name = name.isEmpty ? "vm-\(suffix)" : "\(name)-\(suffix)"
        }
        return name
    }

    static let maxVMNameLength = 52

    /// A VM name derived from `sessionName` that isn't one of `existing`.
    ///
    /// exe.dev rejects a duplicate name outright, so a second session called
    /// "review" would otherwise fail with a raw API error after the integrations
    /// had already been set up. Numbering the name keeps that invisible.
    static func uniqueVMName(from sessionName: String, existing: Set<String>) -> String {
        let base = vmName(from: sessionName)
        guard existing.contains(base) else { return base }

        for counter in 2...99 {
            let candidate = appending("\(counter)", to: base)
            if !existing.contains(candidate) { return candidate }
        }
        // Ninety-eight VMs sharing one name isn't worth counting past.
        return appending(UUID().uuidString.prefix(6).lowercased(), to: base)
    }

    /// Join `suffix` onto `base` with a hyphen, shortening `base` so the result
    /// stays inside the length limit and doesn't end up with a doubled hyphen.
    private static func appending(_ suffix: some StringProtocol, to base: String) -> String {
        let room = maxVMNameLength - suffix.count - 1
        let trimmed = String(base.prefix(room))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(trimmed)-\(suffix)"
    }

    /// Build the remote command run over SSH: write the bootstrap script, make
    /// sure tmux is installed and configured, and hand the connection to tmux in
    /// control mode.
    ///
    /// Nothing may print to stdout before tmux does: stdout *is* the control
    /// protocol the app parses. So, unlike an interactive attach, the bootstrap
    /// script isn't run here — it is the command tmux runs in the session's
    /// first window, where its output belongs to a pane and the user can watch
    /// it in a tab.
    ///
    /// The script is base64-encoded so arbitrary multi-line user content (setup
    /// script, settings JSON) survives the trip through SSH argument and
    /// remote-shell parsing.
    static func command(
        setupScript: String,
        claudeSettings: String,
        repos: [String],
        startCommand: String = "",
        gitIdentity: (name: String, email: String)? = nil,
        model: GatewayModel? = nil
    ) -> String {
        let encoded = Data(script(setupScript: setupScript,
                                  claudeSettings: claudeSettings,
                                  repos: repos,
                                  gitIdentity: gitIdentity,
                                  model: model).utf8).base64EncodedString()
        return "printf %s '\(encoded)' | base64 -d > \(scriptPath)"
            + " && chmod +x \(scriptPath);"
            + " \(installTmux)"
            + " \(enableExtendedKeys)"
            + " \(controlModeCommand(startCommand: startCommand))"
    }

    /// tmux session every VM session attaches to.
    static let tmuxSession = "exe"

    static let scriptPath = "/tmp/exe-bootstrap.sh"

    /// tmux has to exist before it can be started, and it can no longer be
    /// installed by the bootstrap script — that now runs *inside* tmux. Output
    /// is discarded rather than printed because stdout is the control protocol;
    /// a failure surfaces as tmux failing to start, with ssh's stderr shown on
    /// the session.
    static let installTmux = "command -v tmux >/dev/null 2>&1 ||"
        + " { sudo apt-get update -qq >/dev/null 2>&1 &&"
        + " sudo apt-get install -y -qq tmux >/dev/null 2>&1; } || true;"

    /// libghostty sends the kitty keyboard protocol for modified keys (e.g.
    /// Shift+Enter, Shift+Tab), but tmux only forwards it to a pane that asks
    /// for it first — Claude Code never does, so those keys never reach it.
    /// `always` forces tmux to report them unconditionally; `extkeys` is the
    /// matching terminal-features flag tmux checks (the option is spelled
    /// `extended-keys`, but the feature name it looks for is shorter — one
    /// word, not two). Seeded here rather than from the bootstrap script
    /// because the script now runs *inside* tmux, by which time the server has
    /// already read its config; guarded so re-running it doesn't duplicate
    /// the lines.
    static let enableExtendedKeys =
        "grep -qs '^set -g extended-keys always$' \"$HOME/.tmux.conf\" ||"
        + " echo 'set -g extended-keys always' >> \"$HOME/.tmux.conf\";"
        + " grep -qs '^set -as terminal-features .,\\*:extkeys.$' \"$HOME/.tmux.conf\" ||"
        + " echo 'set -as terminal-features \",*:extkeys\"' >> \"$HOME/.tmux.conf\";"

    /// Attach the app to tmux as a control-mode client (`-C`), so each pane's
    /// output arrives as a stream the app renders into its own terminal tab.
    ///
    /// `-A` attaches to the existing session or creates one, so a dropped
    /// connection reattaches with work intact. The trailing command runs *only*
    /// when the session is created, never on attach, so reconnecting never
    /// stacks a second copy of it.
    ///
    /// That command is the session's first window: the bootstrap script, then
    /// the configured start command, then a login shell — so the window stays
    /// open with a prompt once the start command exits, instead of closing the
    /// tab. It runs under a login shell so the user's profile, and therefore
    /// `PATH`, is loaded first. `${SHELL}` stays inside single quotes so it is
    /// expanded remotely, not here.
    static func controlModeCommand(startCommand: String) -> String {
        let trimmed = startCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        var window = "\(scriptPath);"
        if !trimmed.isEmpty {
            window += " \(trimmed);"
        }
        window += " exec ${SHELL:-bash} -l"
        let firstWindow = "${SHELL:-bash} -l -c " + shellQuote(window)
        return "exec tmux -C new-session -A -s \(tmuxSession) \(shellQuote(firstWindow))"
    }

    /// Single-quote for a POSIX shell, escaping embedded single quotes.
    static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The script body that gets base64-encoded into `command`.
    static func script(
        setupScript: String,
        claudeSettings: String,
        repos: [String],
        gitIdentity: (name: String, email: String)? = nil,
        model: GatewayModel? = nil
    ) -> String {
        var script = "#!/usr/bin/env bash\n"

        // Seed the commit identity from the GitHub account, so commits made on
        // the VM are attributed without any manual setup. Only when unset, so a
        // deliberate change on the VM survives reconnects.
        if let gitIdentity {
            script += """
            git config --global user.name >/dev/null 2>&1 || \
            git config --global user.name \(shellQuote(gitIdentity.name))
            git config --global user.email >/dev/null 2>&1 || \
            git config --global user.email \(shellQuote(gitIdentity.email))

            """
        }

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

        // Point the harnesses that read a config file at the chosen gateway
        // model. Claude Code needs nothing here: it reads the ANTHROPIC_*
        // variables set on the VM host when it was created.
        if let model {
            script += harnessConfig(for: model)
        }

        script += setupScript
        script += "\n"

        // A failed clone used to be swallowed by `|| true`, leaving the user in
        // a shell with no repo and git's error scrolled off under the setup
        // script's output. One bad repo still must not abort the rest of the
        // bootstrap, so failures are collected and reported together at the end.
        //
        // The URL is quoted: repo names reach here from the picker but also from
        // the free-text "owner/repo" field, which is only checked for a slash.
        if !repos.isEmpty {
            script += "exe_failed_clones=''\n"
            for repo in repos {
                let url = shellQuote("https://github.int.exe.xyz/\(repo).git")
                script += """
                if ! git clone \(url); then
                  exe_failed_clones="$exe_failed_clones "\(shellQuote(repo))
                fi

                """
            }
            script += """
            if [ -n "$exe_failed_clones" ]; then
              echo "" >&2
              echo "exe: these repositories did not clone:$exe_failed_clones" >&2
              echo "exe: check their GitHub integration on exe.dev, then clone again." >&2
            fi

            """
        }

        // Mark every directory in the home dir as trusted, so Claude Code
        // doesn't prompt per folder. Runs after the clones so the freshly
        // cloned repos are included, and merges into any existing
        // ~/.claude.json rather than replacing real state.
        script += trustHomeDirectories
        return script
    }

    /// Configure Codex and pi for `model`.
    ///
    /// This runs again on every reconnect, so it has to be safe to repeat and
    /// safe to change your mind about. pi's two files are merged key by key,
    /// leaving other providers and settings alone. Codex has no mergeable
    /// format here, so its file is only rewritten when it's absent or already
    /// names our provider — a `config.toml` someone wrote themselves is worth
    /// more than a model selection, and saying so beats overwriting it quietly.
    static func harnessConfig(for model: GatewayModel) -> String {
        let codex = Data(LLMGateway.codexConfig(for: model).utf8).base64EncodedString()
        let provider = Data(LLMGateway.piProvider(for: model).utf8).base64EncodedString()
        let settings = Data(LLMGateway.piSettings(for: model).utf8).base64EncodedString()
        let marker = LLMGateway.providerName

        return """

        mkdir -p "$HOME/.codex"
        if [ ! -e "$HOME/.codex/config.toml" ] || grep -q \(shellQuote(marker)) "$HOME/.codex/config.toml"; then
          printf %s '\(codex)' | base64 -d > "$HOME/.codex/config.toml"
        else
          echo "exe: left ~/.codex/config.toml alone — it doesn't use the \(marker) provider." >&2
        fi

        python3 - <<'PYEOF' || true
        import base64, json, os

        directory = os.path.expanduser("~/.pi/agent")
        os.makedirs(directory, exist_ok=True)

        def load(path):
            try:
                with open(path) as f:
                    data = json.load(f)
            except Exception:
                data = {}
            return data if isinstance(data, dict) else {}

        def save(path, data):
            with open(path, "w") as f:
                json.dump(data, f, indent=2)

        models_path = os.path.join(directory, "models.json")
        models = load(models_path)
        providers = models.get("providers")
        if not isinstance(providers, dict):
            providers = {}
        providers.update(json.loads(base64.b64decode("\(provider)")))
        models["providers"] = providers
        save(models_path, models)

        settings_path = os.path.join(directory, "settings.json")
        settings = load(settings_path)
        settings.update(json.loads(base64.b64decode("\(settings)")))
        save(settings_path, settings)
        PYEOF

        """
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
