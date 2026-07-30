import SwiftUI

/// The horizontal tab strip above the terminal: one tab per tmux pane in the
/// selected session, plus a button for a new tmux window — or, from its menu, a
/// tab showing the VM's Shelley.
///
/// The pane tabs *are* tmux's window list — they are named by tmux and appear and
/// disappear as windows and splits do, whether they were opened from here or by
/// something running on the VM. Shelley tabs are the app's own and sit after
/// them.
struct TerminalTabBar: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(session.tabs) { tab in
                        TerminalTabButton(
                            tab: tab,
                            isSelected: tab.id == session.selectedTabID,
                            onSelect: { session.selectedTabID = tab.id },
                            onClose: { session.closeTab(tab) })
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }

            Divider().frame(height: 16)

            // Clicking + opens a terminal, as it always has; the menu beside it
            // is the way to a Shelley tab instead.
            Menu {
                Button("New Terminal") { session.newTab() }
                Button("New Shelley") { session.newShelleyTab() }
                    .disabled(session.shelleyURL == nil)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
            } primaryAction: {
                session.newTab()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .help("New tmux window (⌥⌘T), or Shelley from the menu")
            .accessibilityLabel("New tab")
        }
        // Fixed, or the scroll view would take the terminal's height with it.
        .frame(height: 30)
        .background(.thinMaterial)
    }
}

private struct TerminalTabButton: View {
    @ObservedObject var tab: TerminalTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        // The label is a Button with the ✕ beside it rather than inside it:
        // a button nested in another button's label doesn't reliably take
        // clicks (the same shape the session sidebar uses).
        HStack(spacing: 4) {
            Button(action: onSelect) {
                Text(tab.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // Long window names shouldn't push the rest of the strip
                    // off the edge.
                    .frame(maxWidth: 160)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.displayName)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 10, height: 10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            // Kept in the layout at zero opacity so tabs don't reflow on hover.
            .opacity(isHovering || isSelected ? 1 : 0)
            .help(tab.isBrowser ? "Close tab" : "Close pane")
            .accessibilityLabel("Close \(tab.displayName)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(background)
        )
        .onHover { isHovering = $0 }
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        return isHovering ? Color.primary.opacity(0.06) : Color.clear
    }
}
