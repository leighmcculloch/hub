import AppKit
import SwiftUI

/// Hosts the terminal surfaces. All sessions' `SurfaceView`s are kept mounted so
/// their terminal state survives tab switches; only the selected one is shown.
///
/// This is deliberately an `NSViewRepresentable` over a container view rather
/// than swapping SwiftUI views, because recreating a `SurfaceView` would tear
/// down and respawn the underlying shell.
struct TerminalHost: NSViewRepresentable {
    @ObservedObject var workspace: Workspace

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.autoresizingMask = [.width, .height]
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Mount any surfaces that aren't in the container yet.
        for session in workspace.sessions {
            let view = session.surfaceView
            if view.superview !== container {
                view.removeFromSuperview()
                view.frame = container.bounds
                view.autoresizingMask = [.width, .height]
                container.addSubview(view)
            }
        }

        // Unmount surfaces whose session was closed.
        let liveViews = Set(workspace.sessions.map { ObjectIdentifier($0.surfaceView) })
        for subview in container.subviews where !liveViews.contains(ObjectIdentifier(subview)) {
            subview.removeFromSuperview()
        }

        // Show only the selected surface and give it focus.
        for session in workspace.sessions {
            let isSelected = session.id == workspace.selectedSessionID
            session.surfaceView.isHidden = !isSelected
            if isSelected {
                container.window?.makeFirstResponder(session.surfaceView)
            }
        }
    }
}
