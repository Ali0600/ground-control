import Foundation

/// What the window does with a navigation the page asked for.
public enum NavigationDecision: Equatable {
    /// Load it inside the app window.
    case allow
    /// Hand it to the user's default browser.
    case openInBrowser(URL)
    /// Drop it. The reason goes to the log.
    case refuse(String)
}

/// The app window shows the dashboard and nothing else.
///
/// A browser would follow any link the page offers; this window is not a browser. The
/// per-port "open" buttons call `window.open("http://localhost:<port>", "_blank")`, which
/// a web view without a UI delegate silently drops — so every new-window request goes to
/// the default browser, as does any link that leaves the dashboard's origin. Only http
/// and https are ever handed on: the page renders text taken from process command lines
/// and repo files, and if an injection ever slipped past its escaping, a `file:` or
/// custom-scheme URL must not reach `NSWorkspace.open`.
public enum NavigationPolicy {
    public static func decide(
        url: URL?,
        dashboard: ServerEndpoint,
        isMainFrame: Bool,
        opensNewWindow: Bool
    ) -> NavigationDecision {
        guard let url else { return .refuse("navigation with no URL") }
        let scheme = url.scheme?.lowercased() ?? ""

        switch scheme {
        case "http", "https":
            if opensNewWindow { return .openInBrowser(url) }
            if dashboard.isSameOrigin(url) { return .allow }
            if isMainFrame { return .openInBrowser(url) }
            return .refuse("an embedded frame tried to load \(url.absoluteString)")
        case "about":
            // WebKit's own blank page — harmless in place, never worth a window.
            if !opensNewWindow, url.absoluteString.lowercased() == "about:blank" { return .allow }
            return .refuse("\(url.absoluteString) is not opened from the dashboard")
        default:
            return .refuse("\(scheme.isEmpty ? "a URL with no scheme" : "\(scheme): URLs") "
                + "are not opened from the dashboard")
        }
    }
}
