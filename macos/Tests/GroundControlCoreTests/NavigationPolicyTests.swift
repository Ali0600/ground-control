import XCTest

@testable import GroundControlCore

final class NavigationPolicyTests: XCTestCase {
    private let dashboard = ServerEndpoint.standard

    private func decide(
        _ raw: String?, mainFrame: Bool = true, newWindow: Bool = false
    ) -> NavigationDecision {
        NavigationPolicy.decide(
            url: raw.flatMap(URL.init(string:)), dashboard: dashboard,
            isMainFrame: mainFrame, opensNewWindow: newWindow)
    }

    func testTheDashboardLoadsInTheWindow() {
        XCTAssertEqual(decide("http://127.0.0.1:8787/"), .allow)
        XCTAssertEqual(decide("http://127.0.0.1:8787/#ports"), .allow)
        XCTAssertEqual(decide("http://127.0.0.1:8787/api/agents", mainFrame: false), .allow)
    }

    /// The per-port "open" button: window.open("http://localhost:<port>", "_blank").
    func testThePortOpenButtonGoesToTheBrowser() {
        let url = URL(string: "http://localhost:3000")!
        XCTAssertEqual(decide(url.absoluteString, newWindow: true), .openInBrowser(url))
    }

    func testEveryNewWindowGoesToTheBrowserEvenSameOrigin() {
        let url = URL(string: "http://127.0.0.1:8787/api/agents")!
        XCTAssertEqual(decide(url.absoluteString, newWindow: true), .openInBrowser(url))
    }

    func testALinkThatLeavesTheDashboardGoesToTheBrowser() {
        for raw in ["https://github.com/", "http://localhost:8787/", "http://127.0.0.1:8788/",
                    "https://127.0.0.1:8787/"] {
            XCTAssertEqual(decide(raw), .openInBrowser(URL(string: raw)!), raw)
        }
    }

    func testAnEmbeddedFrameCannotLoadAnotherOrigin() {
        guard case .refuse = decide("https://example.com/", mainFrame: false) else {
            return XCTFail("a subframe to another origin must be refused, not opened in the browser")
        }
    }

    /// Only http(s) ever reaches NSWorkspace.open — a file: or custom-scheme URL from an
    /// injected string must die here, in either kind of navigation.
    func testOtherSchemesAreRefusedEverywhere() {
        for raw in ["file:///etc/hosts", "javascript:alert(1)", "data:text/html,hi",
                    "vscode://file/tmp", "x-apple.systempreferences:", "blob:http://127.0.0.1:8787/x"] {
            for newWindow in [false, true] {
                guard case .refuse = decide(raw, newWindow: newWindow) else {
                    return XCTFail("\(raw) (newWindow: \(newWindow)) must be refused")
                }
            }
        }
    }

    func testAboutBlankStaysPutButNeverOpensAWindow() {
        XCTAssertEqual(decide("about:blank"), .allow)
        guard case .refuse = decide("about:blank", newWindow: true) else {
            return XCTFail("a blank popup is not worth a browser tab")
        }
        guard case .refuse = decide("about:srcdoc", newWindow: false) else {
            return XCTFail("only about:blank is allowed")
        }
    }

    func testNoURLIsRefused() {
        guard case .refuse = decide(nil) else { return XCTFail() }
    }
}
