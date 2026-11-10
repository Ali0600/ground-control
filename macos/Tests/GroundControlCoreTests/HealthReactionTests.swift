import XCTest

@testable import GroundControlCore

final class HealthReactionTests: XCTestCase {
    private let offline = ServerHealth.offline("Could not connect to the server.")
    private let online = ServerHealth.online(alerts: 2)

    func testTheDashboardSurvivesOneMissedPollButNotTwo() {
        XCTAssertEqual(HealthReaction.to(offline, in: WindowState(screen: .dashboard, offlineStreak: 1)), .none)
        XCTAssertEqual(
            HealthReaction.to(offline, in: WindowState(screen: .dashboard, offlineStreak: 2)), .showUnreachable)
    }

    func testTheOfflineScreenRedrawsOnEveryMissSoItsAdviceStaysCurrent() {
        XCTAssertEqual(
            HealthReaction.to(offline, in: WindowState(screen: .unreachable, offlineStreak: 9)), .showUnreachable)
    }

    func testAStartGetsItsFastPollWindowBeforeItCountsAsFailed() {
        XCTAssertEqual(HealthReaction.to(offline, in: WindowState(screen: .starting, isPollingFast: true)), .none)
        XCTAssertEqual(HealthReaction.to(offline, in: WindowState(screen: .starting, actionInFlight: true)), .none)
        XCTAssertEqual(
            HealthReaction.to(offline, in: WindowState(screen: .starting)), .showUnreachable,
            "a server that never came back must not leave the spinner up forever")
    }

    func testALoadInFlightReportsItsOwnFailure() {
        XCTAssertEqual(HealthReaction.to(offline, in: WindowState(screen: .connecting, isLoading: true)), .none)
    }

    func testTheServerComingBackReloadsTheDashboardOnce() {
        for screen in [DashboardScreen.unreachable, .starting, .connecting] {
            XCTAssertEqual(HealthReaction.to(online, in: WindowState(screen: screen)), .loadDashboard, "\(screen)")
            XCTAssertEqual(
                HealthReaction.to(online, in: WindowState(screen: screen, isLoading: true)), .none,
                "\(screen): a load already in flight must not be started twice")
            XCTAssertEqual(
                HealthReaction.to(online, in: WindowState(screen: screen, actionInFlight: true)), .none,
                "\(screen): the old server may still be answering while launchctl restarts it")
        }
        XCTAssertEqual(HealthReaction.to(online, in: WindowState(screen: .dashboard)), .none)
    }

    /// An answer we can't read still means the server is up: show the page.
    func testAnUnexpectedAnswerCountsAsUp() {
        XCTAssertEqual(
            HealthReaction.to(.unexpected("HTTP 500"), in: WindowState(screen: .unreachable)), .loadDashboard)
    }
}
