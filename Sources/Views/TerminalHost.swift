import AppKit
import SwiftUI
import Termini

/// Hosts the terminal surfaces, and the web view of any Shelley tab. Every tab
/// that has been shown keeps its surface mounted so the terminal state — or the
/// loaded page — survives switching; only the selected one is drawn and takes
/// input.
struct TerminalHost: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var config = AppConfig.shared

    /// The app's effective light/dark appearance. The app doesn't force an
    /// appearance, so this tracks the system — and when it flips, the terminal
    /// surface is re-themed to match (see `appearance` below).
    @Environment(\.colorScheme) private var colorScheme

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
                        Group {
                            if let browser = tab.browser {
                                BrowserPane(browser: browser)
                            } else {
                                TerminiTerminalView(
                                    controller: tab.controller,
                                    appearance: appearance,
                                    isRenderVisible: isSelected
                                )
                            }
                        }
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
            focusSelected()
        }
        .onChange(of: workspace.selectedSession?.selectedTab?.id) {
            mountSelected()
            focusSelected()
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

    /// A surface that is already mounted won't focus itself. Deferred to the
    /// next runloop turn: selecting a session is usually a click on a sidebar
    /// row, and that row's own button takes first responder as part of the
    /// same click — a focus() call made synchronously here would just lose
    /// that race.
    private func focusSelected() {
        DispatchQueue.main.async {
            guard let tab = workspace.selectedSession?.selectedTab else { return }
            // A Shelley tab's terminal surface is never on screen; focusing it
            // would take the keyboard away from the page.
            if let browser = tab.browser {
                browser.focus()
            } else {
                tab.controller.focus()
            }
        }
    }

    /// The font is set here; colours come from a `TerminiTerminalTheme` picked
    /// to match the app's appearance — a light preset when the desktop is in
    /// light mode, a dark one otherwise. The surface applies the theme's OSC
    /// colour sequences live, so flipping the system appearance re-themes every
    /// mounted surface without a relaunch. Padding still rides along via the
    /// extra config file below.
    private var appearance: TerminiTerminalAppearance {
        TerminiTerminalAppearance(
            theme: colorScheme == .light ? .blueprint : .midnightBloom,
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
