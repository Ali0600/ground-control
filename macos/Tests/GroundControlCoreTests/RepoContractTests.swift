import XCTest

@testable import GroundControlCore

/// The app hard-codes facts that live in OTHER files of this repo: the page's tab list,
/// the agent's label and port, the hosts the server accepts, a README heading, the
/// Info.plist's security keys. Each pair can drift without either side failing on its
/// own, so each is read from the source of truth here.
final class RepoContractTests: XCTestCase {
    /// …/macos/Tests/GroundControlCoreTests/RepoContractTests.swift → the repo root.
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func read(_ path: String) throws -> String {
        try String(contentsOf: Self.repo.appendingPathComponent(path), encoding: .utf8)
    }

    /// The first capture group of `pattern` in `text`, or a failure naming what was missing.
    private func capture(_ pattern: String, in text: String, _ what: String) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        let match = try XCTUnwrap(regex.firstMatch(in: text, range: range), "could not find \(what)")
        return try XCTUnwrap(Range(match.range(at: 1), in: text).map { String(text[$0]) })
    }

    private func quotedStrings(_ list: String) -> [String] {
        list.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }

    func testTheViewMenuHasExactlyThePagesTabs() throws {
        let page = try read("app/main.py")
        let tabs = quotedStrings(try capture(#"const TABS = \[([^\]]*)\]"#, in: page, "const TABS"))
        XCTAssertEqual(DashboardTab.allCases.map(\.rawValue), tabs)
        for tab in DashboardTab.allCases {
            XCTAssertTrue(page.contains("id=\"tab-\(tab.rawValue)\""), "the page has no tab-\(tab.rawValue) button to click")
        }
    }

    func testTheAgentIsTheOneTheTemplateInstalls() throws {
        let data = try Data(contentsOf: Self.repo.appendingPathComponent("com.launchddash.server.plist.example"))
        let plist = try XCTUnwrap(AgentPlist.parse(data), "the template no longer parses")
        XCTAssertEqual(plist.label, ServerAgent.label)
        XCTAssertEqual(plist.port, ServerEndpoint.defaultPort, "the template's --port")
        XCTAssertNotNil(plist.logPath, "Show Server Log reads StandardOutPath from the installed plist")
    }

    func testTheDefaultPortIsRunShs() throws {
        let port = try capture(#"PORT="\$\{PORT:-(\d+)\}""#, in: try read("run.sh"), "run.sh's PORT default")
        XCTAssertEqual(Int(port), ServerEndpoint.defaultPort)
    }

    /// A host the app allows but the server's TrustedHostMiddleware rejects would load a
    /// 400 page instead of the dashboard.
    func testEveryHostTheAppAcceptsIsOneTheServerAccepts() throws {
        // To the list's closing "])", not the first "]": "[::1]" is one of the entries.
        let hosts = try capture(#"allowed_hosts=\[(.*)\]\)"#, in: try read("app/main.py"), "allowed_hosts")
        let serverHosts = Set(quotedStrings(hosts).map(ServerEndpoint.normalizedHost))
        XCTAssertTrue(
            ServerEndpoint.loopbackHosts.isSubset(of: serverHosts),
            "app accepts \(ServerEndpoint.loopbackHosts.sorted()), server accepts \(serverHosts.sorted())")
    }

    /// The Dock badge counts `active` — the list the page counts for its "(N!)" title.
    func testTheBadgeReadsTheListThePageCounts() throws {
        let page = try read("app/main.py")
        let route = try capture(#"def api_watch\(\)[^\n]*\n((?:.*\n){1,25})"#, in: page, "def api_watch()")
        XCTAssertTrue(route.contains(#""active": ["#), "/api/watch no longer returns an `active` list")
        XCTAssertTrue(page.contains("const n = w.active.length;"), "the page's title badge no longer counts `active`")
    }

    func testTheSetupGuideLinkPointsAtAHeadingTheReadmeHas() throws {
        let readme = try read("README.md")
        let headings = readme.split(separator: "\n").filter { $0.hasPrefix("## ") }.map {
            $0.dropFirst(3).lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        }
        XCTAssertTrue(
            headings.contains(ProjectLinks.setupGuideAnchor),
            "README has no heading for #\(ProjectLinks.setupGuideAnchor) (has \(headings))")
    }

    /// The bundle's security posture: plain http to THIS Mac only, never to the web.
    func testInfoPlistAllowsLocalNetworkingAndNothingWider() throws {
        let data = try Data(contentsOf: Self.repo.appendingPathComponent("macos/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let ats = try XCTUnwrap(info["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
        for wider in ["NSAllowsArbitraryLoads", "NSAllowsArbitraryLoadsInWebContent",
                      "NSAllowsArbitraryLoadsForMedia", "NSExceptionDomains"] {
            XCTAssertNil(ats[wider], "\(wider) would let the window load plain http from the internet")
        }
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "GroundControl", "the executable target's name")
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertTrue(try read("macos/build.sh").contains("AppIcon.icns"), "build.sh must write the icon Info.plist names")

        let minimum = try capture(#"\.macOS\(\.v(\d+)\)"#, in: try read("macos/Package.swift"), "platforms")
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "\(minimum).0", "Package.swift's platform")
    }
}
