import SwiftUI

@main
struct ExeDesktopAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var workspace = Workspace()
    @ObservedObject private var config = AppConfig.shared

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
                Button("New Browser Tab") { workspace.newBrowserTab() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }

            CommandGroup(after: .sidebar) {
                Button("Toggle Sessions Sidebar") { workspace.showSessionSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Toggle Worktree Diff") { workspace.showDiffSidebar.toggle() }
                    .keyboardShortcut("r", modifiers: .command)
            }

            // Terminal zoom. Both ⌘+ and ⌘= increase, since ⌘+ needs shift on
            // most layouts.
            CommandGroup(after: .toolbar) {
                Button("Increase Font Size") { config.adjustFontSize(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Increase Font Size", action: { config.adjustFontSize(by: 1) })
                    .keyboardShortcut("=", modifiers: .command)
                Button("Decrease Font Size") { config.adjustFontSize(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Reset Font Size") { config.data.fontSize = 13 }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
