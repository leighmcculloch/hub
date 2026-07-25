import AppKit
import SwiftUI

/// Settings: exe.dev credentials, terminal appearance, environment variables,
/// the per-session setup script, and the Claude settings seeded onto each VM.
/// All are persisted to the JSON config in Application Support.
struct SettingsView: View {
    @ObservedObject private var config = AppConfig.shared

    /// Monospaced faces installed on the system, for the font picker.
    private var monospacedFonts: [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        return Array(Set(names.filter { !$0.hasPrefix(".") })).sorted()
    }

    var body: some View {
        Form {
            Section("exe.dev") {
                SecureField("API token", text: $config.data.exeToken, prompt: Text("exe1.…"))
                Text("Used to create VMs and GitHub integrations. Leave blank to use the EXE_DEV_TOKEN environment variable. Stored in Application Support, never in the repo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Terminal") {
                Picker("Font", selection: $config.data.fontName) {
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
                Text("⌘+ / ⌘- adjust size, ⌘0 resets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Environment variables") {
                Text("Set on the host when each VM is created, so every process on the VM sees them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach($config.data.environment) { $variable in
                    HStack(spacing: 6) {
                        TextField("KEY", text: $variable.key)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        Text("=").foregroundStyle(.secondary)
                        TextField("value", text: $variable.value)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            config.data.environment.removeAll { $0.id == variable.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }

                Button {
                    config.data.environment.append(EnvVar())
                } label: {
                    Label("Add Variable", systemImage: "plus")
                }
                .buttonStyle(.plain)
            }

            Section("Start command") {
                TextField("start command", text: $config.data.startCommand, prompt: Text("e.g. claude"))
                Text("Run in the login shell after connecting. Leave empty to go straight to the shell. When the command exits you're returned to a shell rather than losing the session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Setup script") {
                Text("Runs over SSH as the first command on each new VM, before the repos are cloned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $config.data.setupScript)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }

            Section("Claude settings (~/.claude/settings.json)") {
                HStack {
                    Text("Written to each new VM, unless the VM already has one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Default") {
                        config.data.claudeSettings = AppConfigData.defaultClaudeSettings
                    }
                    .font(.caption)
                }
                TextEditor(text: $config.data.claudeSettings)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 820)
    }
}
