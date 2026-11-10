import AppKit
import GroundControlCore
import WebKit
import XCTest

@testable import GroundControl

/// Drives the window's REAL web view: WebKit calls the real delegate methods, which run
/// the real policy. Only the two outermost effects are stood in for — handing a URL to
/// the browser, and putting a dialog on screen — so nothing opens on the machine running
/// the tests. The window is never shown.
@MainActor
final class WebViewIntegrationTests: XCTestCase {
    private var controller: DashboardWindowController!
    private var opened: [URL] = []
    private var dialogs: [String] = []

    override func setUp() async throws {
        _ = NSApplication.shared // windows and the offline screen's icon need NSApp
        opened = []
        dialogs = []
        controller = DashboardWindowController(
            endpoint: ServerEndpoint(host: "127.0.0.1", port: 8787), remembersFrame: false)
        controller.openExternally = { [unowned self] url in
            self.opened.append(url)
            return true
        }
    }

    override func tearDown() async throws {
        controller.webView.stopLoading()
        controller.close()
        controller = nil
    }

    /// Serves `body` as if it came from the dashboard's origin — no server involved.
    private func loadPage(_ body: String) async {
        controller.webView.loadHTMLString(
            "<!doctype html><title>Ground Control</title><body>\(body)</body>",
            baseURL: controller.endpoint.url)
        await eventually("the page to finish loading") { self.controller.screen == .dashboard }
    }

    private func js(_ script: String) async throws -> Any? {
        try await controller.webView.evaluateJavaScript(script)
    }

    /// Bounded wait: fails at the deadline instead of hanging the suite.
    @discardableResult
    private func eventually(
        _ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(what)")
                return false
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    // MARK: - Links

    /// The per-port "open" button is exactly this call.
    func testWindowOpenHandsTheURLToTheBrowserInsteadOfOpeningAWindow() async throws {
        await loadPage("")
        _ = try await js(#"window.open("http://localhost:3000/", "_blank"); true"#)
        await eventually("window.open to reach the browser") { !self.opened.isEmpty }
        XCTAssertEqual(opened, [URL(string: "http://localhost:3000/")!])
        XCTAssertEqual(controller.webView.url, controller.endpoint.url, "the dashboard stays put")
    }

    func testATargetBlankLinkGoesToTheBrowser() async throws {
        await loadPage(#"<a id="l" href="http://localhost:4000/x" target="_blank">open</a>"#)
        _ = try await js(#"document.getElementById("l").click(); true"#)
        await eventually("the link to reach the browser") { !self.opened.isEmpty }
        XCTAssertEqual(opened, [URL(string: "http://localhost:4000/x")!])
    }

    func testALinkThatLeavesTheDashboardGoesToTheBrowserAndThePageStays() async throws {
        await loadPage("")
        _ = try await js(#"location.href = "https://example.com/docs"; true"#)
        await eventually("the navigation to reach the browser") { !self.opened.isEmpty }
        XCTAssertEqual(opened, [URL(string: "https://example.com/docs")!])
        XCTAssertEqual(controller.screen, .dashboard)
        XCTAssertEqual(controller.webView.url, controller.endpoint.url)
    }

    /// Refusals are checked against a control that DOES reach the browser afterwards:
    /// "nothing was opened" alone would also pass if the delegate were never called.
    func testOtherSchemesAndEmbeddedFramesNeverReachTheBrowser() async throws {
        await loadPage(#"<iframe src="https://example.com/embedded"></iframe>"#)
        _ = try await js(#"window.open("file:///etc/hosts"); window.open("vscode://file/tmp"); true"#)
        _ = try await js(#"window.open("http://localhost:3000/control"); true"#)
        await eventually("the control link to reach the browser") { !self.opened.isEmpty }
        XCTAssertEqual(opened, [URL(string: "http://localhost:3000/control")!])
    }

    // MARK: - Dialogs

    func testAlertIsShownAndThePageContinuesAfterIt() async throws {
        await loadPage("")
        controller.presentAlert = { [unowned self] alert, done in
            self.dialogs.append(alert.informativeText)
            done(.alertFirstButtonReturn)
        }
        let result = try await js(#"alert("Port 3000 is free"); "after""#)
        XCTAssertEqual(result as? String, "after")
        XCTAssertEqual(dialogs, ["Port 3000 is free"])
    }

    /// Without a UI delegate WebKit answers every confirm() with false, so only a TRUE
    /// proves the panel was asked.
    func testConfirmReturnsTheButtonPressed() async throws {
        await loadPage("")
        controller.presentAlert = { _, done in done(.alertFirstButtonReturn) }
        let ok = try await js(#"confirm("Stop it?") ? "yes" : "no""#)
        XCTAssertEqual(ok as? String, "yes")
        controller.presentAlert = { _, done in done(.alertSecondButtonReturn) }
        let cancel = try await js(#"confirm("Stop it?") ? "yes" : "no""#)
        XCTAssertEqual(cancel as? String, "no")
    }

    func testPromptReturnsWhatWasTyped() async throws {
        await loadPage("")
        controller.presentAlert = { alert, done in
            (alert.accessoryView as? NSTextField)?.stringValue = "8080"
            done(.alertFirstButtonReturn)
        }
        let typed = try await js(#"prompt("Which port?", "3000")"#)
        XCTAssertEqual(typed as? String, "8080")
    }

    /// With no visible window there is nobody to ask: the cautious answer, at once.
    func testADialogWithNoWindowOnScreenGetsTheCautiousAnswer() {
        XCTAssertFalse(controller.window?.isVisible ?? true)
        var answers: [NSApplication.ModalResponse] = []
        let confirm = NSAlert()
        confirm.addButton(withTitle: "OK")
        confirm.addButton(withTitle: "Cancel")
        controller.present(confirm) { answers.append($0) }
        let alert = NSAlert()
        alert.addButton(withTitle: "OK")
        controller.present(alert) { answers.append($0) }
        XCTAssertEqual(answers, [.alertSecondButtonReturn, .alertFirstButtonReturn])
    }

    // MARK: - Page state

    func testTheWindowTitleFollowsThePage() async throws {
        await loadPage("")
        _ = try await js(#"document.title = "(3!) Ground Control"; true"#)
        await eventually("the title to follow") { self.controller.window?.title == "(3!) Ground Control" }
        _ = try await js(#"document.title = ""; true"#)
        await eventually("an empty title to fall back") { self.controller.window?.title == "Ground Control" }
    }

    func testATabMenuItemClicksThePagesOwnButton() async throws {
        await loadPage(#"<button id="tab-ports" onclick="window.clicked = 'ports'">Ports</button>"#)
        controller.select(.ports)
        var clicked: String?
        await eventually("the tab button to be clicked") {
            Task { clicked = try? await self.js("window.clicked || ''") as? String }
            return clicked == "ports"
        }
    }

    // MARK: - Failures

    func testNothingListeningIsReportedAsALoadFailure() async throws {
        controller = DashboardWindowController(
            endpoint: ServerEndpoint(host: "127.0.0.1", port: try Self.unusedPort()), remembersFrame: false)
        var reasons: [String] = []
        controller.onLoadFailed = { reasons.append($0) }
        controller.loadDashboard()
        await eventually("the refused connection to be reported") { !reasons.isEmpty }
        XCTAssertNotEqual(controller.screen, .dashboard)
        XCTAssertFalse(controller.isLoading)
    }

    /// A load replaced by a newer one, or cancelled by this window's own policy, is not
    /// the server failing — it must not put "isn't answering" on screen.
    func testCancelledLoadsAreNotFailures() {
        var reasons: [String] = []
        controller.onLoadFailed = { reasons.append($0) }
        let webView = controller.webView
        controller.webView(webView, didFailProvisionalNavigation: nil,
                           withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        controller.webView(webView, didFail: nil, withError: NSError(domain: "WebKitErrorDomain", code: 102))
        XCTAssertEqual(reasons, [])
        controller.webView(webView, didFailProvisionalNavigation: nil,
                           withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
        XCTAssertEqual(reasons.count, 1, "a refused connection IS a failure")
    }

    /// A port nothing listens on: bind an ephemeral one, read it, let it go.
    private static func unusedPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("no socket") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw XCTSkip("could not bind a port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
