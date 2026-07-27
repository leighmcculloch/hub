import Combine
import Foundation
import WebKit

/// Owns a `WKWebView` for a browser tab in the right sidebar.
///
/// The web view lives in the model (like `TerminalSession`'s terminal surface)
/// so the page survives switching between sidebar tabs instead of reloading.
final class BrowserModel: NSObject, ObservableObject {
    let webView = WKWebView()

    /// What's in the address bar. Diverges from the loaded page while typing,
    /// then re-syncs when navigation finishes.
    @Published var address: String
    @Published var isLoading = false
    @Published var pageTitle = ""
    @Published var canGoBack = false
    @Published var canGoForward = false

    init(initialAddress: String) {
        address = initialAddress
        super.init()
        webView.navigationDelegate = self
        load()
    }

    /// Load whatever is in the address bar.
    func load() {
        guard let url = Self.url(from: address) else { return }
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func reload() {
        // A tab whose first load failed has no back/forward item to reload.
        if webView.url == nil { load() } else { webView.reload() }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    /// Accept bare hostnames like `foo.exe.xyz`, defaulting to https.
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return URL(string: trimmed) }
        return URL(string: "https://\(trimmed)")
    }

    private func syncNavigationState() {
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let current = webView.url?.absoluteString { address = current }
        pageTitle = webView.title ?? ""
    }
}

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        syncNavigationState()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        syncNavigationState()
    }
}

/// One tab in the right sidebar. There is always a diff tab; browser tabs are
/// added by the user and can be closed.
final class SidebarTab: ObservableObject, Identifiable {
    enum Kind {
        case diff
        case browser
    }

    let id = UUID()
    let kind: Kind
    /// Non-nil only for `.browser` tabs.
    let browser: BrowserModel?

    private var titleObserver: AnyCancellable?
    @Published var title: String

    init(kind: Kind, title: String, browser: BrowserModel? = nil) {
        self.kind = kind
        self.title = title
        self.browser = browser

        // Name the tab after the page once it has loaded, falling back to the
        // host so an untitled page still reads sensibly.
        if let browser {
            titleObserver = browser.$pageTitle
                .combineLatest(browser.$address)
                .sink { [weak self] pageTitle, address in
                    guard let self else { return }
                    if !pageTitle.isEmpty {
                        self.title = pageTitle
                    } else if let host = BrowserModel.url(from: address)?.host {
                        self.title = host
                    }
                }
        }
    }
}
