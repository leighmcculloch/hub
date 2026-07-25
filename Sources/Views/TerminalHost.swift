import AppKit
import SwiftUI

/// Hosts the terminal views. All sessions' terminal views are kept mounted so
/// their terminal state survives tab switches; only the selected one is shown.
///
/// This is deliberately an `NSViewRepresentable` over a container view rather
/// than swapping SwiftUI views, because recreating a terminal view would tear
/// down and respawn the underlying shell.
struct TerminalHost: NSViewRepresentable {
    @ObservedObject var workspace: Workspace

    /// Breathing room so terminal text doesn't sit hard against the pane edges.
    private static let padding: CGFloat = 8

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.autoresizingMask = [.width, .height]
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Mount any surfaces that aren't in the container yet, inset so the text
        // has padding inside the pane.
        let pad = Self.padding
        for session in workspace.sessions {
            let view = session.terminalView
            if view.superview !== container {
                view.removeFromSuperview()
                view.frame = container.bounds.insetBy(dx: pad, dy: pad)
                view.autoresizingMask = [.width, .height]
                container.addSubview(view)
            }
        }

        // Unmount surfaces whose session was closed.
        let liveViews = Set(workspace.sessions.map { ObjectIdentifier($0.terminalView) })
        for subview in container.subviews where !liveViews.contains(ObjectIdentifier(subview)) {
            subview.removeFromSuperview()
        }

        // Show only the selected surface and give it focus.
        for session in workspace.sessions {
            let isSelected = session.id == workspace.selectedSessionID
            session.terminalView.isHidden = !isSelected
            if isSelected {
                container.window?.makeFirstResponder(session.terminalView)
            }
        }
    }
}
