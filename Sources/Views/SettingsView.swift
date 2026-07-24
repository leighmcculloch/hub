import SwiftUI

/// Settings: the exe.dev API token and the per-session setup script. Both are
/// persisted to the JSON config in Application Support.
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

            Section("Setup script") {
                Text("Runs over SSH as the first command on each new VM tab, before the repos are cloned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $config.data.setupScript)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 380)
    }
}
