import XCTest

@testable import GroundControlCore

final class ServerHealthTests: XCTestCase {
    private func classify(_ json: String, status: Int = 200) -> ServerHealth {
        ServerHealth.classify(statusCode: status, body: Data(json.utf8), error: nil)
    }

    func testTheBadgeCountsTheActiveList() {
        XCTAssertEqual(classify(#"{"active": [], "events": []}"#), .online(alerts: 0))
        XCTAssertNil(classify(#"{"active": []}"#).badgeLabel, "no alerts, no badge")
        let three = classify(#"{"active": [{"key": "a"}, {"key": "b"}, {"key": "c"}]}"#)
        XCTAssertEqual(three, .online(alerts: 3))
        XCTAssertEqual(three.badgeLabel, "3")
        XCTAssertEqual(ServerHealth.online(alerts: 99).badgeLabel, "99")
        XCTAssertEqual(ServerHealth.online(alerts: 150).badgeLabel, "99+")
    }

    /// "Couldn't tell" must never look like "nothing to report".
    func testAnUnreadableAnswerIsUnknownNotZero() {
        let unreadable = [
            classify("<html>Internal Server Error</html>"),
            classify(#"{"events": []}"#),          // the field was renamed or dropped
            classify(#"{"active": "3"}"#),
            classify(#"[{"key": "a"}]"#),
            classify(#"{"active": []}"#, status: 500),
            ServerHealth.classify(statusCode: 200, body: nil, error: nil),
        ]
        for health in unreadable {
            guard case .unexpected = health else { return XCTFail("expected unexpected, got \(health)") }
            XCTAssertEqual(health.badgeLabel, "?")
            XCTAssertTrue(health.isOnline, "something answered, so the server is up")
        }
    }

    func testNothingAnsweringIsOffline() {
        let refused = ServerHealth.classify(
            statusCode: nil, body: nil, error: URLError(.cannotConnectToHost))
        guard case .offline = refused else { return XCTFail("\(refused)") }
        XCTAssertEqual(refused.badgeLabel, "off")
        XCTAssertFalse(refused.isOnline)
        // An error wins even if a status code came with it.
        guard case .offline = ServerHealth.classify(
            statusCode: 200, body: Data(), error: URLError(.timedOut))
        else { return XCTFail() }
        guard case .offline = ServerHealth.classify(statusCode: nil, body: nil, error: nil) else {
            return XCTFail("no response and no error is still no response")
        }
    }
}
