import SwiftUI
import WebKit

/// Address bar + navigation controls over a `WKWebView`. Shown for a browser tab
/// in the right sidebar, and for a Shelley tab in the terminal space.
struct BrowserPane: View {
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
