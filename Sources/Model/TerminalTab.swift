import Combine
import Foundation
import Termini

/// One tab in the terminal space, and the terminal surface it shows.
///
/// A VM session has one tab per tmux pane, identified by `paneID`; a local shell
/// has a single tab whose surface is driven by a local PTY.
///
/// Main-actor isolated, like the surface controller it owns.
@MainActor
final class TerminalTab: ObservableObject, Identifiable {
    /// `nonisolated` so `Identifiable` is satisfied off the main actor too.
    nonisolated let id = UUID()

    /// The tmux pane this renders, e.g. `%3`. nil for a local shell.
    let paneID: String?

    /// The tmux window the pane belongs to, e.g. `@1`. Not known for a tab
    /// created from a pane's output before the listing that describes it.
    var windowID: String?

    /// The tab's transport end, kept alive for the tab's lifetime — the
    /// emulator's state (scrollback, modes, what's on screen) lives behind it,
    /// so it must survive tab switches. Output that arrives before a surface is
    /// mounted is held by the controller and replayed to the surface when one
    /// is, so a background pane doesn't lose what it printed.
    let controller: TerminiTerminalController

    @Published var title: String

    /// Where tmux last reported this pane's cursor. Held because the screen is
    /// restored from a `capture-pane` reply that arrives after the pane
    /// listing that described it.
    var cursor: (x: Int, y: Int) = (0, 0)

    init(paneID: String?, title: String) {
        self.paneID = paneID
        self.title = title
        controller = TerminiTerminalController()
    }

    var displayName: String { title.isEmpty ? "Terminal" : title }
}
