import AppKit
import SwiftUI

/// Hosts the terminal views. Every session's tabs are kept mounted so their
/// terminal state survives switching; only the selected one is shown.
///
/// This is deliberately an `NSViewRepresentable` over a container view rather
/// than swapping SwiftUI views, because recreating a terminal view would tear
/// down and respawn the underlying shell.
struct TerminalHost: NSViewRepresentable {
    @ObservedObject var workspace: Workspace

    /// Breathing room so terminal text doesn't sit hard against the pane edges.
    private static let padding: CGFloat = 8

    func makeNSView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.autoresizingMask = [.width, .height]
        // Layer-backed so the padding around the terminal can be filled with the
        // terminal's own background colour instead of showing the window behind.
        container.wantsLayer = true
        return container
    }

    /// Take exactly the space offered. Without this SwiftUI consults the hosted
    /// terminal, whose size quantises to whole character cells, and the layout
    /// fights the sidebar dividers while they're being dragged.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ContainerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    /// Reports no intrinsic size, so the terminal inside can't push the
    /// surrounding layout around either.
    final class ContainerView: NSView {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
    }

    func updateNSView(_ container: ContainerView, context: Context) {
        // Every tab of every session, not just the visible one: a mounted view
        // is laid out even while hidden, so a tab is already the right size
        // when it is switched to, instead of reflowing its pane's output.
        let tabs = workspace.sessions.flatMap(\.tabs)

        // Mount any surfaces that aren't in the container yet, inset so the text
        // has padding inside the pane.
        let pad = Self.padding
        for tab in tabs where tab.view.superview !== container {
            let view = tab.view
            view.removeFromSuperview()
            view.frame = container.bounds.insetBy(dx: pad, dy: pad)
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }

        // Unmount surfaces whose session was closed or whose pane went away.
        let liveViews = Set(tabs.map { ObjectIdentifier($0.view) })
        for subview in container.subviews where !liveViews.contains(ObjectIdentifier(subview)) {
            subview.removeFromSuperview()
        }

        // Show only the selected session's selected tab, and give it focus.
        let visible = workspace.selectedSession?.selectedTab
        for tab in tabs {
            let isVisible = tab.id == visible?.id
            tab.view.isHidden = !isVisible
            if isVisible {
                container.window?.makeFirstResponder(tab.view)
                // Match the padding to the terminal so the inset is invisible.
                container.layer?.backgroundColor = tab.view.nativeBackgroundColor.cgColor
            }
        }
    }
}
