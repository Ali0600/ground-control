import AppKit
import GroundControlCore
import WebKit

/// The one window: the dashboard in a web view, with the native offline screen in front
/// of it whenever the page is not showing.
@MainActor
final class DashboardWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate {
    enum Screen: Equatable {
        /// Loading the page (first launch, or after an outage).
        case connecting
        /// The page is up.
        case dashboard
        /// Nothing answered; the offline screen explains and offers a fix.
        case unreachable
        /// A start or restart is under way.
        case starting
    }

    private static let zoomKey = "PageZoom"

    let endpoint: ServerEndpoint
    let webView: WKWebView
    let offlineView = OfflineView(frame: .zero)
    private(set) var screen: Screen = .connecting
    private(set) var isLoading = false
    /// Why a load failed; the app shows it and decides what happens next.
    var onLoadFailed: ((String) -> Void)?
    /// Hands a URL to the default browser. Tests put a recorder here, so the web view's
    /// real delegate path is exercised without opening anyone's browser.
    var openExternally: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    /// Shows a page dialog and reports the button pressed. Tests answer it directly.
    lazy var presentAlert: (NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Void = {
        [unowned self] alert, completion in self.present(alert, completion: completion)
    }
    private var titleObservation: NSKeyValueObservation?

    /// - Parameter remembersFrame: keep the window's size and place between launches
    ///   (off in tests, which must not write the frame into anyone's defaults).
    init(endpoint: ServerEndpoint, remembersFrame: Bool = true) {
        self.endpoint = endpoint

        let configuration = WKWebViewConfiguration()
        // Nothing to keep: the page stores nothing on purpose (demo mode depends on it),
        // and a fresh fetch after an update beats a cached copy of the old page.
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = "GroundControlMac/\(Bundle.main.shortVersion)"
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = Palette.background
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        let zoom = UserDefaults.standard.double(forKey: DashboardWindowController.zoomKey)
        if zoom > 0 { webView.pageZoom = CGFloat(zoom) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Ground Control"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.background
        window.minSize = NSSize(width: 720, height: 480)
        // Closing keeps the window (and the page's polling) for the Dock icon to reopen.
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        let container = NSView()
        for view in [webView, offlineView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        window.contentView = container
        window.center()
        if remembersFrame { window.setFrameAutosaveName("GroundControlDashboard") }

        super.init(window: window)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // The page writes "(N!) Ground Control" when alerts are waiting; the window title
        // follows it, as a browser tab would.
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                let title = webView.title ?? ""
                self?.window?.title = title.isEmpty ? "Ground Control" : title
            }
        }
        show(.connecting)
        offlineView.showConnecting(endpoint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("DashboardWindowController is built in code") }

    // MARK: - Screens

    func loadDashboard() {
        isLoading = true
        if screen != .dashboard {
            offlineView.showConnecting(endpoint)
            show(.connecting)
        }
        // Reload where the user was: the tab lives in the URL hash (/#ports).
        let target = webView.url.flatMap { endpoint.isSameOrigin($0) ? $0 : nil } ?? endpoint.url
        webView.load(URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
    }

    func showUnreachable(reason: String?, advice: OfflineAdvice?, note: String?, logAvailable: Bool) {
        offlineView.showUnreachable(
            endpoint: endpoint, reason: reason, advice: advice, note: note, logAvailable: logAvailable)
        show(.unreachable)
    }

    func showStarting(_ message: String) {
        offlineView.showStarting(message)
        show(.starting)
    }

    private func show(_ screen: Screen) {
        // Logged on change only, so Console tells the story of an outage line by line.
        if screen != self.screen { NSLog("Ground Control: screen → %@", "\(screen)") }
        self.screen = screen
        webView.isHidden = screen != .dashboard
        offlineView.isHidden = screen == .dashboard
    }

    /// What "Open in Browser" opens: the page as it stands, tab included.
    var browserURL: URL {
        webView.url.flatMap { endpoint.isSameOrigin($0) ? $0 : nil } ?? endpoint.url
    }

    func select(_ tab: DashboardTab) {
        guard screen == .dashboard else { return }
        webView.evaluateJavaScript(tab.activationScript) { result, error in
            if let error {
                NSLog("Ground Control: switching to %@ failed: %@", tab.rawValue, error.localizedDescription)
            } else if (result as? Bool) != true {
                NSLog("Ground Control: the page has no tab-%@ button to click", tab.rawValue)
            }
        }
    }

    /// `factor` multiplies the current zoom; `nil` resets it.
    func zoom(by factor: CGFloat?) {
        let zoom = factor.map { min(max(webView.pageZoom * $0, 0.5), 3) } ?? 1
        webView.pageZoom = zoom
        UserDefaults.standard.set(Double(zoom), forKey: DashboardWindowController.zoomKey)
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // targetFrame is nil for a link that asks for a new window (target=_blank).
        let decision = NavigationPolicy.decide(
            url: navigationAction.request.url, dashboard: endpoint,
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
            opensNewWindow: navigationAction.targetFrame == nil)
        decisionHandler(apply(decision))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        show(.dashboard)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    /// The page's renderer is a separate process; if it dies (memory pressure, a crash)
    /// the view goes blank and stays blank unless someone reloads it.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("Ground Control: the page's web content process exited; reloading")
        loadDashboard()
    }

    private func loadFailed(_ error: Error) {
        let nsError = error as NSError
        // A load replaced by a newer one, or one this window's policy cancelled, is not
        // the server failing — showing "isn't answering" for it would be a false alarm.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return } // interrupted by policy
        isLoading = false
        onLoadFailed?(nsError.localizedDescription)
    }

    // MARK: - WKUIDelegate

    /// `window.open(...)` — the per-port "open" buttons. Returning nil means no in-app
    /// window; the URL goes to the browser instead (or nowhere, if the policy refuses it).
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        _ = apply(NavigationPolicy.decide(
            url: navigationAction.request.url, dashboard: endpoint,
            isMainFrame: true, opensNewWindow: true))
        return nil
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
    ) {
        let alert = panel(message)
        alert.addButton(withTitle: "OK")
        presentAlert(alert) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = panel(message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        presentAlert(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = panel(prompt)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        presentAlert(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    // MARK: - Helpers

    private func apply(_ decision: NavigationDecision) -> WKNavigationActionPolicy {
        switch decision {
        case .allow:
            return .allow
        case .openInBrowser(let url):
            if !openExternally(url) {
                NSLog("Ground Control: could not open %@ in the browser", url.absoluteString)
            }
            return .cancel
        case .refuse(let reason):
            NSLog("Ground Control: refused a navigation: %@", reason)
            return .cancel
        }
    }

    private func panel(_ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Ground Control"
        alert.informativeText = message
        return alert
    }

    /// A page dialog nobody can see (the window is closed) is answered with the cautious
    /// default — OK for an alert, Cancel for a confirm — instead of popping a modal
    /// over whatever the user is doing.
    func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window, window.isVisible else {
            completion(alert.buttons.count > 1 ? .alertSecondButtonReturn : .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }
}
