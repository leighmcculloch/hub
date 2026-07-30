import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // We use our own vertical session tab bar plus subtabs in the terminal
        // and right sidebar, not the standard macOS window tab bar. Opt out of
        // native tabbing app-wide so the system "Show Tab Bar" menu item (View
        // menu) is disabled; each window also sets tabbingMode = .disallowed.
        NSWindow.allowsAutomaticWindowTabbing = false
    }
}
