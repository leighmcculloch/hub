import AppKit
import SwiftUI
import Termini

/// Hosts the terminal surfaces. Every tab that has been shown keeps its surface
/// mounted so the terminal state survives switching; only the selected one is
/// drawn and takes input.
struct TerminalHost: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var config = AppConfig.shared

    /// Tabs whose surface has been created. A surface takes first responder as
    /// it comes up, so one is mounted only once its tab has been selected —
    /// otherwise a session attaching to a tmux that already has several panes
    /// would leave the keyboard on whichever surface happened to finish last.
    /// Until then a pane's output waits in its controller and is replayed when
    /// the surface arrives.
    @State private var mounted: Set<TerminalTab.ID> = []

    var body: some View {
        ZStack {
            ForEach(workspace.sessions) { session in
                ForEach(session.tabs) { tab in
                    if mounted.contains(tab.id) {
                        let isSelected = isSelected(session: session, tab: tab)
                        TerminiTerminalView(
                            controller: tab.controller,
                            appearance: appearance,
                            isRenderVisible: isSelected
                        )
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { mountSelected() }
        .onChange(of: workspace.selectedSessionID) {
            mountSelected()
            // A surface that is already mounted won't focus itself.
            workspace.selectedSession?.selectedTab?.controller.focus()
        }
        .onChange(of: workspace.selectedSession?.selectedTab?.id) {
            mountSelected()
            workspace.selectedSession?.selectedTab?.controller.focus()
        }
    }

    private func isSelected(session: TerminalSession, tab: TerminalTab) -> Bool {
        session.id == workspace.selectedSessionID
            && tab.id == session.selectedTab?.id
    }

    private func mountSelected() {
        guard let id = workspace.selectedSession?.selectedTab?.id else { return }
        mounted.insert(id)
    }

    /// Only the font is set here: it's in Settings and on ⌘+/⌘-. Colours and
    /// anything else come from ghostty's own config, which it loads itself.
    private var appearance: TerminiTerminalAppearance {
        TerminiTerminalAppearance(
            fontSize: config.data.fontSize,
            fontFamily: TerminiTerminalFontFamily(
                name: Self.familyName(of: config.data.fontName)),
            extraConfigFilePaths: [GhosttyPadding.path].compactMap { $0 })
    }

    /// The font picker lists font names ("SFMono-Regular"), and ghostty matches
    /// on the family ("SF Mono").
    private static func familyName(of fontName: String) -> String {
        NSFont(name: fontName, size: 12)?.familyName ?? fontName
    }
}

/// Breathing room so terminal text doesn't sit hard against the pane edges.
///
/// Padding has to be ghostty's rather than a SwiftUI inset around the surface:
/// only ghostty knows the terminal's background colour, so an inset added out
/// here would be a band of the wrong colour. libghostty has no C setter for it,
/// so it goes in as a config file the surface loads.
private enum GhosttyPadding {
    static let path: String? = {
        let contents = "window-padding-x = 8\nwindow-padding-y = 8\n"
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExeDesktopApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ghostty-padding.conf")
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return url.path
    }()
}
