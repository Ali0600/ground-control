import Foundation

/// One poll of `GET /api/watch`, classified.
///
/// Three outcomes, kept apart on purpose. "No alerts" and "couldn't tell" must never
/// collapse into one: a badge that goes blank when the answer is unreadable would look
/// exactly like a healthy machine.
public enum ServerHealth: Equatable {
    /// The server answered with the shape we know. `alerts` is the length of its
    /// `active` list — the same number the page puts in its `(N!)` title.
    case online(alerts: Int)
    /// Something answered, but not with that shape (an error page, a 500, a renamed
    /// field). The server is up; the count is unknown.
    case unexpected(String)
    /// Nothing answered: refused, timed out, or the connection dropped.
    case offline(String)

    public static func classify(statusCode: Int?, body: Data?, error: Error?) -> ServerHealth {
        if let error { return .offline(error.localizedDescription) }
        guard let statusCode else { return .offline("no HTTP response") }
        guard statusCode == 200 else { return .unexpected("HTTP \(statusCode) from /api/watch") }
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body),
              let object = json as? [String: Any]
        else { return .unexpected("/api/watch did not return a JSON object") }
        guard let active = object["active"] as? [Any] else {
            return .unexpected("/api/watch has no \u{201C}active\u{201D} list")
        }
        return .online(alerts: active.count)
    }

    /// What the Dock icon shows. `nil` means no badge — a healthy machine with nothing
    /// to acknowledge.
    public var badgeLabel: String? {
        switch self {
        case .online(let n): return n <= 0 ? nil : (n > 99 ? "99+" : String(n))
        case .unexpected: return "?"
        case .offline: return "off"
        }
    }

    public var isOnline: Bool {
        if case .offline = self { return false }
        return true
    }
}
