import AppKit
import Foundation
import SwiftUI

/// Settings: exe.dev credentials, terminal appearance, the environments a
/// session can be run in, global environment variables, and the Claude settings
/// seeded onto each VM. All are persisted to the JSON config in Application
/// Support.
///
/// Split across tabs rather than one long form: it's the macOS Settings
/// convention, and it keeps the window short enough to fit on any display even
/// with the two script editors.
struct SettingsView: View {
    @ObservedObject private var config = AppConfig.shared

    /// Monospaced faces installed on the system, for the font picker.
    private var monospacedFonts: [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        return Array(Set(names.filter { !$0.hasPrefix(".") })).sorted()
    }

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            terminal
                .tabItem { Label("Terminal", systemImage: "terminal") }
            environments
                .tabItem { Label("Environments", systemImage: "wrench.and.screwdriver") }
            globalVariables
                .tabItem { Label("Variables", systemImage: "list.bullet.rectangle") }
            claudeSettings
                .tabItem { Label("Claude", systemImage: "sparkles") }
        }
        .frame(width: 600, height: 460)
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section("exe.dev") {
                SecureField("API token", text: $config.data.exeToken, prompt: Text("exe1.…"))
                caption("Used to create VMs and GitHub integrations. Leave blank to use the EXE_DEV_TOKEN environment variable. Stored in Application Support, never in the repo.")
                // The env-var fallback is invisible otherwise, so confirm which
                // source is actually in play.
                if config.data.exeToken.isEmpty {
                    if ProcessInfo.processInfo.environment["EXE_DEV_TOKEN"] != nil {
                        status(ok: true, "Using EXE_DEV_TOKEN from the environment.")
                    } else {
                        status(ok: false, "No token configured — creating a VM will fail.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Terminal

    private var terminal: some View {
        Form {
            Section("Font") {
                Picker("Face", selection: $config.data.fontName) {
                    ForEach(monospacedFonts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                HStack {
                    Text("Size")
                    Slider(value: $config.data.fontSize, in: 8...32, step: 1)
                    Text("\(Int(config.data.fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                caption("⌘+ / ⌘- adjust size, ⌘0 resets.")
            }

            Section("Preview") {
                Text("exe $ git status --short\n M Sources/Views/SettingsView.swift")
                    .font(.custom(config.data.fontName, size: CGFloat(config.data.fontSize)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Environments

    /// One environment at a time, chosen from the picker at the top. A list
    /// beside a form would halve the width available to the setup script, and
    /// these are edited one at a time anyway.
    private var environments: some View {
        Form {
            Section {
                HStack(spacing: 6) {
                    Picker("Environment", selection: environmentSelection) {
                        ForEach(config.data.environments) { environment in
                            Text(environmentName(environment)).tag(Optional(environment.id))
                        }
                    }
                    Button {
                        let added = SessionEnvironment(name: "New Environment")
                        config.data.environments.append(added)
                        config.data.selectedEnvironmentID = added.id
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add an environment")
                    Button(role: .destructive) {
                        removeSelectedEnvironment()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .help("Remove this environment")
                    // The last one can't go: a session has to run something.
                    .disabled(config.data.environments.count <= 1)
                }
                caption("New sessions use the environment selected here; it can also be changed on the New Session sheet.")
            }

            if let index = selectedEnvironmentIndex {
                Section("Name") {
                    TextField("Name", text: $config.data.environments[index].name)
                        .labelsHidden()
                }

                Section("Start command") {
                    TextField("Start command",
                              text: $config.data.environments[index].startCommand,
                              prompt: Text("e.g. claude"))
                        .labelsHidden()
                    caption("Every session runs inside a tmux session named \"\(Bootstrap.tmuxSession)\", so a dropped connection reattaches with your work intact. This command runs inside it, and only when the session is first created — reconnecting attaches instead of starting a second copy. Leave empty for a plain shell.")
                }

                Section("Environment variables") {
                    caption("Set on the host alongside the global variables when a VM using this environment is created.")
                    variableEditor($config.data.environments[index].environment)
                }

                Section("Setup script") {
                    caption("Runs over SSH as the first command on each new VM, before the repos are cloned.")
                    editor(text: $config.data.environments[index].setupScript)
                        .frame(height: 140)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Nil selections and ids left over from a deleted environment both resolve
    /// to the one actually in use, so the picker is never blank.
    private var environmentSelection: Binding<UUID?> {
        Binding(
            get: { config.data.selectedEnvironment.id },
            set: { config.data.selectedEnvironmentID = $0 }
        )
    }

    private var selectedEnvironmentIndex: Int? {
        config.data.environments.firstIndex { $0.id == config.data.selectedEnvironment.id }
    }

    private func environmentName(_ environment: SessionEnvironment) -> String {
        environment.name.isEmpty ? "Untitled" : environment.name
    }

    private func removeSelectedEnvironment() {
        guard config.data.environments.count > 1, let index = selectedEnvironmentIndex else { return }
        config.data.environments.remove(at: index)
        config.data.selectedEnvironmentID = config.data.environments.first?.id
    }

    // MARK: - Global variables

    private var globalVariables: some View {
        Form {
            Section("Global environment variables") {
                caption("Set on the host when each VM is created, whichever environment it uses, so every process on the VM sees them.")
                variableEditor($config.data.globalEnvironment)
            }
        }
        .formStyle(.grouped)
    }

    /// The key/value rows, shared by the global list and each environment's.
    @ViewBuilder
    private func variableEditor(_ variables: Binding<[EnvVar]>) -> some View {
        if variables.wrappedValue.isEmpty {
            Text("No variables set.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        } else {
            // Column headings label the two same-looking fields. The fields
            // deliberately carry no placeholder, which would repeat these
            // labels.
            HStack(spacing: 6) {
                Text("Key").frame(width: 140, alignment: .leading)
                Text("Value").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.trailing, 24)

            ForEach(variables) { $variable in
                HStack(spacing: 6) {
                    TextField("", text: $variable.key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 140)
                        .accessibilityLabel("Key")
                    TextField("", text: $variable.value)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .accessibilityLabel("Value")
                    Button {
                        variables.wrappedValue.removeAll { $0.id == variable.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove \(variable.key.isEmpty ? "this variable" : variable.key)")
                }
            }
        }

        HStack {
            Button {
                variables.wrappedValue.append(EnvVar())
            } label: {
                Label("Add Variable", systemImage: "plus")
            }
            Spacer()
            // Nameless rows are dropped when the VM is created; say so rather
            // than letting them look active.
            if variables.wrappedValue.contains(where: { $0.key.isEmpty }) {
                status(ok: false, "Rows without a name are ignored.")
            }
        }
    }

    // MARK: - Claude settings

    private var claudeSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude settings").font(.headline)
                Spacer()
                Button("Restore Default") {
                    config.data.claudeSettings = AppConfigData.defaultClaudeSettings
                }
            }
            caption("Written to ~/.claude/settings.json on each new VM, unless the VM already has one.")
            editor(text: $config.data.claudeSettings)
            // Malformed JSON only surfaces on the VM otherwise, long after the
            // typo was made.
            if isValidJSON(config.data.claudeSettings) {
                status(ok: true, "Valid JSON.")
            } else {
                status(ok: false, "Not valid JSON — the VM may reject these settings.")
            }
        }
        .padding(16)
    }

    // MARK: - Helpers

    private func editor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12, design: .monospaced))
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline confirmation/warning line, tinted so the state reads at a glance.
    private func status(ok: Bool, _ text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(ok ? Color.green : Color.orange)
    }

    private func isValidJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}
