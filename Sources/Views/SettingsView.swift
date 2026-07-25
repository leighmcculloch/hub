import SwiftUI

/// Settings: the exe.dev API token, environment variables set on each VM, and
/// the per-session setup script. All are persisted to the JSON config in
/// Application Support.
struct SettingsView: View {
    @ObservedObject private var config = AppConfig.shared

    var body: some View {
        Form {
            Section("exe.dev") {
                SecureField("API token", text: $config.data.exeToken, prompt: Text("exe1.…"))
                Text("Used to create VMs and GitHub integrations. Leave blank to use the EXE_DEV_TOKEN environment variable. Stored in Application Support, never in the repo.")
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
                            .frame(width: 130)
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

            Section("Setup script") {
                Text("Runs over SSH as the first command on each new VM tab, before the repos are cloned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $config.data.setupScript)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 520)
    }
}
