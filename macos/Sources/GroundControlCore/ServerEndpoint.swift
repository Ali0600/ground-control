import Foundation

/// Where the dashboard lives.
///
/// The server binds loopback only (`run.sh` pins `--host 127.0.0.1`), and its whole
/// security model assumes nothing else can reach it. So the app refuses to point its
/// window anywhere else: a `ServerURL` setting that names another machine is ignored and
/// reported, never followed.
public struct ServerEndpoint: Equatable {
    /// `run.sh`'s default `PORT`, and the port in `com.launchddash.server.plist.example`.
    /// Pinned to both by `RepoContractTests`.
    public static let defaultPort = 8787
    public static let standard = ServerEndpoint(host: "127.0.0.1", port: defaultPort)

    /// The user-defaults key that overrides the address, e.g.
    /// `defaults write com.launchddash.groundcontrol ServerURL http://127.0.0.1:9000`.
    public static let settingKey = "ServerURL"

    /// Hosts the server's `TrustedHostMiddleware` accepts (`app/main.py`). Anything else
    /// is either another machine or a name the server would reject with a 400 anyway.
    public static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// Lowercased, with IPv6 brackets stripped.
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = ServerEndpoint.normalizedHost(host)
        self.port = port
    }

    /// `127.0.0.1:8787`, or `[::1]:8787` — IPv6 needs brackets or the port reads as part
    /// of the address.
    public var authority: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// The dashboard's root page.
    public var url: URL {
        // Built from validated parts, so it always parses.
        URL(string: "http://\(authority)/")!
    }

    /// The JSON the Dock badge is computed from: the same `active` list the page counts
    /// for its `(N!)` title.
    public var watchURL: URL {
        URL(string: "http://\(authority)/api/watch")!
    }

    public var isStandard: Bool { self == ServerEndpoint.standard }

    /// Does `url` belong to this dashboard (same scheme, host and port)?
    ///
    /// Exact origin semantics on purpose: `localhost:8787` is the same server as
    /// `127.0.0.1:8787` but a different origin, and treating them as one would be a rule
    /// the browser does not share.
    public func isSameOrigin(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "http", let host = parts.host
        else { return false }
        return ServerEndpoint.normalizedHost(host) == self.host && (parts.port ?? 80) == port
    }

    /// Resolve the configured address. `nil` or empty means the standard one.
    ///
    /// A value that is not a loopback `http://host:port` origin falls back to the
    /// standard address AND returns a warning — the app shows it on the "can't reach the
    /// server" screen, so a typo in the setting is visible where the user is looking
    /// instead of silently pointing the window somewhere else.
    public static func resolve(_ raw: String?) -> (endpoint: ServerEndpoint, warning: String?) {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (standard, nil) }

        func refuse(_ why: String) -> (endpoint: ServerEndpoint, warning: String?) {
            (standard, "Ignored the \(settingKey) setting \u{201C}\(trimmed)\u{201D}: \(why). "
                + "Using \(standard.authority).")
        }

        // Without "://", "localhost:9000" parses as scheme "localhost" — say what is
        // wrong rather than complaining about the scheme.
        guard trimmed.contains("://"), let parts = URLComponents(string: trimmed),
              let scheme = parts.scheme
        else {
            return refuse("it is not a URL like http://127.0.0.1:\(defaultPort)")
        }
        guard scheme.lowercased() == "http" else {
            return refuse("the dashboard is served over http://")
        }
        guard parts.user == nil, parts.password == nil else {
            return refuse("it carries a user name or password")
        }
        guard let rawHost = parts.host, !rawHost.isEmpty else {
            return refuse("it has no host")
        }
        let host = normalizedHost(rawHost)
        guard loopbackHosts.contains(host) else {
            return refuse("the server only listens on this Mac (127.0.0.1, localhost or ::1)")
        }
        guard parts.path.isEmpty || parts.path == "/", parts.query == nil, parts.fragment == nil
        else {
            return refuse("it should be just the address, with no path")
        }
        let port = parts.port ?? 80
        guard (1...65_535).contains(port) else {
            return refuse("\(port) is not a port number")
        }
        return (ServerEndpoint(host: host, port: port), nil)
    }

    static func normalizedHost(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        return h
    }
}
