import AppKit
import Combine
import SwiftTerm

/// One tab in the terminal space, and the terminal view it shows.
///
/// A VM session has one tab per tmux pane, identified by `paneID`; a local shell
/// has a single tab whose view runs the process itself.
final class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()

    /// The tmux pane this renders, e.g. `%3`. nil for a local shell.
    let paneID: String?

    /// The tmux window the pane belongs to, e.g. `@1`. Not known for a tab
    /// created from a pane's output before the listing that describes it.
    var windowID: String?

    /// Kept alive for the tab's lifetime — the emulator's state (scrollback,
    /// modes, what's on screen) lives in it, so it must survive tab switches.
    let view: TerminalView

    @Published var title: String

    /// Where tmux last reported this pane's cursor. Held because the screen is
    /// restored from a `capture-pane` reply that arrives after the pane
    /// listing that described it.
    var cursor: (x: Int, y: Int) = (0, 0)

    init(paneID: String?, view: TerminalView, title: String) {
        self.paneID = paneID
        self.view = view
        self.title = title
    }

    var displayName: String { title.isEmpty ? "Terminal" : title }
}
