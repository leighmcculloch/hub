import SwiftUI
import WebKit

/// The right sidebar. Its sub-tabs belong to the selected session, so switching
/// sessions swaps the whole sidebar. The diff tab is permanent; browser tabs are
/// added with the + button and default to that session's instance URL.
struct RightSidebar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        Group {
            if let session = workspace.selectedSession {
                SessionSidebarTabs(workspace: workspace, session: session)
            } else {
                DiffSidebar(workspace: workspace)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial)
    }
}

/// The tab strip and content pane for one session's sidebar.
private struct SessionSidebarTabs: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            content
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(session.sidebarTabs) { tab in
                        SidebarTabChip(
                            tab: tab,
                            isSelected: tab.id == session.selectedSidebarTab?.id,
                            onSelect: { session.selectedSidebarTabID = tab.id },
                            onClose: { session.closeSidebarTab(tab) }
                        )
                    }
                }
            }

            Button(action: { session.newBrowserTab() }) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New browser tab" + (session.webURL.map { " (\($0))" } ?? ""))
            .accessibilityLabel("New browser tab")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var content: some View {
        // Within a session every tab stays mounted, so a browser tab doesn't
        // reload and the diff tab keeps its poll loop when you switch tabs.
        // Across sessions the subtree is rebuilt, but each browser's WKWebView
        // is owned by its model, so pages survive that too.
        ZStack {
            ForEach(session.sidebarTabs) { tab in
                Group {
                    switch tab.kind {
                    case .diff:
                        DiffSidebar(workspace: workspace)
                    case .browser:
                        if let browser = tab.browser {
                            BrowserPane(browser: browser)
                        }
                    }
                }
                .opacity(tab.id == session.selectedSidebarTab?.id ? 1 : 0)
                .allowsHitTesting(tab.id == session.selectedSidebarTab?.id)
            }
        }
    }
}

/// One chip in the sub-tab strip.
private struct SidebarTabChip: View {
    @ObservedObject var tab: SidebarTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tab.kind == .diff ? "plusminus" : "globe")
                .font(.system(size: 9))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

            Text(tab.title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 110, alignment: .leading)

            // Only browser tabs close; keep the slot empty for the diff tab so
            // chips don't change width on hover.
            if tab.kind != .diff {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(isHovering || isSelected ? 1 : 0)
                .accessibilityLabel("Close \(tab.title)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.18)
                      : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(tab.title)
    }
}

/// Address bar + navigation controls over a `WKWebView`.
private struct BrowserPane: View {
    @ObservedObject var browser: BrowserModel
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            WebViewHost(webView: browser.webView)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button(action: { browser.goBack() }) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(!browser.canGoBack)
            .help("Back")

            Button(action: { browser.goForward() }) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(!browser.canGoForward)
            .help("Forward")

            Button(action: { browser.reload() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Reload")

            TextField("URL", text: $browser.address)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .focused($addressFocused)
                .onSubmit {
                    browser.load()
                    addressFocused = false
                }

            if browser.isLoading {
                ProgressView().controlSize(.mini)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// Hosts the model-owned `WKWebView`, so the page persists across tab switches.
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
