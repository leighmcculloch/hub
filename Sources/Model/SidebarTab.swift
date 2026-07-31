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

    /// Called once with the first prompt typed into a Shelley tab, so the app
    /// can name the VM from it the way Claude Code's hook would. nil for an
    /// ordinary browser tab, which has no prompt to capture.
    private let onFirstPrompt: ((String) -> Void)?
    /// The relay registered as the message handler, held so it can be torn down
    /// after the first prompt. The content controller also retains it; this is
    /// so removal is reachable without the controller knowing our name.
    private var firstPromptRelay: FirstPromptRelay?
    /// One prompt names one VM: further messages are ignored even if the page
    /// reloads and re-runs the capture script.
    private var firstPromptFired = false

    init(initialAddress: String, onFirstPrompt: ((String) -> Void)? = nil) {
        self.address = initialAddress
        self.onFirstPrompt = onFirstPrompt
        super.init()
        webView.navigationDelegate = self
        if onFirstPrompt != nil {
            installFirstPromptCapture()
        }
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

    /// Put the keyboard in the page, the way a terminal tab focuses its surface.
    func focus() {
        webView.window?.makeFirstResponder(webView)
    }

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

    // MARK: - First-prompt capture (Shelley)

    /// Wires the page to report its first chat message back to the app. The
    /// script wraps `fetch` at document start; the relay receives what it posts
    /// without the content controller retaining `self` — the cycle that would
    /// otherwise keep this model and its web view alive after the tab closes.
    private func installFirstPromptCapture() {
        let controller = webView.configuration.userContentController
        let relay = FirstPromptRelay(self)
        firstPromptRelay = relay
        controller.add(relay, contentWorld: .page, name: AutoName.messageHandlerName)
        controller.addUserScript(WKUserScript(
            source: AutoName.firstPromptCaptureScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page))
    }

    /// Called by the relay on the first message from the page. Hands the prompt
    /// to the closure once, then unregisters the handler so a reloaded page
    /// finds no handler to post to and the capture goes quiet for good.
    func receiveFirstPrompt(_ message: WKScriptMessage) {
        guard !firstPromptFired else { return }
        let prompt: String?
        if let object = message.body as? [String: Any] {
            prompt = object["prompt"] as? String
        } else {
            prompt = message.body as? String
        }
        guard let prompt, !prompt.isEmpty else { return }
        firstPromptFired = true
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: AutoName.messageHandlerName)
        firstPromptRelay = nil
        onFirstPrompt?(prompt)
    }
}

/// Forwards a `WKScriptMessageHandler` callback to `BrowserModel` through a
/// weak reference, so the content controller — which retains its handlers —
/// can't keep the model (and its web view) alive past the tab's lifetime.
private final class FirstPromptRelay: NSObject, WKScriptMessageHandler {
    weak var sink: BrowserModel?
    init(_ sink: BrowserModel) { self.sink = sink; super.init() }
    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        sink?.receiveFirstPrompt(message)
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
