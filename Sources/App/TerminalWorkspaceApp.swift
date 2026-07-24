import SwiftUI

@main
struct TerminalWorkspaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace = Workspace()

    var body: some Scene {
        WindowGroup {
            ContentView(workspace: workspace)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session…") { workspace.presentingNewSession = true }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Local Shell") { workspace.newLocalSession() }
                    .keyboardShortcut("t", modifiers: [.command, .control])
                Button("Close Session") { workspace.closeSelectedSession() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Worktree Diff") { workspace.showDiffSidebar.toggle() }
                    .keyboardShortcut("d", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
