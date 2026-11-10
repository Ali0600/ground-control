import Foundation

/// The launchd agent that serves the dashboard: `com.launchddash.server`.
///
/// The app is a CLIENT of that agent and never runs a server of its own. The agent is
/// what keeps the network watch and its banners going while no window is open; a
/// second copy started by the app would fight it for the port.
public struct ServerAgent: Equatable {
    /// The label in `com.launchddash.server.plist.example` (pinned by `RepoContractTests`).
    /// It keeps the project's old name on purpose: installed plists and running jobs
    /// refer to it, so it is an identity, not a display string.
    public static let label = "com.launchddash.server"

    public let uid: UInt32
    public let home: URL

    public init(uid: UInt32, home: URL) {
        self.uid = uid
        self.home = home
    }

    /// Where the README's install step writes the plist.
    public var plistURL: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(ServerAgent.label).plist")
    }

    public var domain: String { "gui/\(uid)" }
    public var service: String { "\(domain)/\(ServerAgent.label)" }

    /// Exits 0 when launchd knows the service (113 when it does not).
    public var printArguments: [String] { ["print", service] }

    /// The `launchctl` arguments for an action, or `nil` when no command performs it.
    public func arguments(for action: ServerAction) -> [String]? {
        switch action {
        // Without -k, kickstart leaves a running job alone — right for "start".
        case .start: return ["kickstart", service]
        // -k kills and relaunches: what picks up new server code after a merge.
        case .restart: return ["kickstart", "-k", service]
        // An installed-but-unloaded agent; its RunAtLoad starts it.
        case .load: return ["bootstrap", domain, plistURL.path]
        case .openSetupGuide: return nil
        }
    }
}

/// Something the "can't reach the server" screen can do about it.
public enum ServerAction: Equatable {
    case start
    case restart
    case load
    case openSetupGuide

    public var buttonTitle: String {
        switch self {
        case .start, .load: return "Start Server"
        case .restart: return "Restart Server"
        case .openSetupGuide: return "Open Setup Guide"
        }
    }
}

/// Three top-level fields of `launchctl print`, for display only.
///
/// That output is written for people, not programs, so nothing DECIDES on it: whether the
/// agent is loaded comes from the command's exit status. A field this cannot find is left
/// out of the message, never guessed.
public struct AgentSnapshot: Equatable {
    public var state: String?
    public var pid: Int?
    public var lastExitCode: String?

    public init(state: String? = nil, pid: Int? = nil, lastExitCode: String? = nil) {
        self.state = state
        self.pid = pid
        self.lastExitCode = lastExitCode
    }

    public static func parse(launchctlPrint text: String) -> AgentSnapshot {
        var snapshot = AgentSnapshot()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Exactly one leading tab: the service's own fields. Nested blocks (its
            // coalitions, endpoints, environment) sit deeper and repeat names like
            // `state = active` that describe something else.
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let body = line.dropFirst()
            guard let eq = body.range(of: " = ") else { continue }
            let key = String(body[..<eq.lowerBound])
            let value = String(body[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "state" where snapshot.state == nil: snapshot.state = value
            case "pid" where snapshot.pid == nil: snapshot.pid = Int(value)
            case "last exit code" where snapshot.lastExitCode == nil:
                snapshot.lastExitCode = value
            default: break
            }
        }
        return snapshot
    }
}

/// The two keys of the installed plist the app cares about.
public struct AgentPlist: Equatable {
    /// `StandardOutPath`, else `StandardErrorPath` — the template points both at one file.
    public var logPath: String?
    /// The `--port` in `ProgramArguments`, if there is one.
    public var port: Int?
    public var label: String?

    public init(logPath: String? = nil, port: Int? = nil, label: String? = nil) {
        self.logPath = logPath
        self.port = port
        self.label = label
    }

    public static func parse(_ data: Data) -> AgentPlist? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any]
        else { return nil }
        var plist = AgentPlist()
        plist.label = dict["Label"] as? String
        plist.logPath = (dict["StandardOutPath"] as? String) ?? (dict["StandardErrorPath"] as? String)
        if let args = dict["ProgramArguments"] as? [String] {
            for (i, arg) in args.enumerated() {
                if arg == "--port", i + 1 < args.count {
                    plist.port = Int(args[i + 1])
                } else if arg.hasPrefix("--port=") {
                    plist.port = Int(arg.dropFirst("--port=".count))
                }
            }
        }
        return plist
    }
}

/// Where the agent stands, as far as launchd can say.
public enum AgentInstall: Equatable {
    case notInstalled
    case installedNotLoaded
    case loaded(AgentSnapshot)

    /// - Parameters:
    ///   - printStatus: the exit status of `launchctl print <service>`.
    ///   - plistExists: whether the plist is at `ServerAgent.plistURL`.
    public static func classify(printStatus: Int32, printOutput: String, plistExists: Bool)
        -> AgentInstall
    {
        if printStatus == 0 { return .loaded(AgentSnapshot.parse(launchctlPrint: printOutput)) }
        return plistExists ? .installedNotLoaded : .notInstalled
    }
}

/// What the "can't reach the server" screen says, and the one button it offers besides
/// Retry. `action` is `nil` when no launchctl command would help.
public struct OfflineAdvice: Equatable {
    public let detail: String
    public let action: ServerAction?

    public init(detail: String, action: ServerAction?) {
        self.detail = detail
        self.action = action
    }
}

extension AgentInstall {
    /// - Parameter agentPort: the `--port` in the installed plist. When it differs from
    ///   the port the app is watching, restarting would change nothing, so the advice
    ///   names the mismatch instead.
    public func advice(endpoint: ServerEndpoint, agentPort: Int?) -> OfflineAdvice {
        switch self {
        case .notInstalled:
            return OfflineAdvice(
                detail: "The server agent (\(ServerAgent.label)) isn\u{2019}t installed on this "
                    + "Mac. Set it up once from your checkout and it stays up \u{2014} see "
                    + "\u{201C}Run it as an always-on agent\u{201D} in the README.",
                action: .openSetupGuide)
        case .installedNotLoaded:
            return OfflineAdvice(
                detail: "The server agent is installed but not loaded, so launchd isn\u{2019}t "
                    + "running it.",
                action: .load)
        case .loaded(let snapshot):
            if let agentPort, agentPort != endpoint.port {
                return OfflineAdvice(
                    detail: "The server agent serves port \(agentPort), but this app is looking "
                        + "at port \(endpoint.port). Set the app\u{2019}s \(ServerEndpoint.settingKey) "
                        + "to http://127.0.0.1:\(agentPort), or change the agent\u{2019}s --port.",
                    action: nil)
            }
            if let pid = snapshot.pid {
                return OfflineAdvice(
                    detail: "The server agent is running (pid \(pid)) but hasn\u{2019}t answered. "
                        + "It may still be starting up, or it may be stuck.",
                    action: .restart)
            }
            var detail = "The server agent is loaded but not running"
            if let code = snapshot.lastExitCode, !code.hasPrefix("(") {
                detail += " \u{2014} it last exited with code \(code)"
            }
            return OfflineAdvice(detail: detail + ".", action: .start)
        }
    }
}
