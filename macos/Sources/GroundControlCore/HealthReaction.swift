import Foundation

/// What the window is showing.
public enum DashboardScreen: Equatable {
    /// Loading the page (first launch, or after an outage).
    case connecting
    /// The page is up.
    case dashboard
    /// Nothing answered; the offline screen explains and offers a fix.
    case unreachable
    /// A start or restart is under way.
    case starting
}

/// Everything the app weighs when a poll lands.
public struct WindowState: Equatable {
    public var screen: DashboardScreen
    /// A page load is in flight; it will report for itself.
    public var isLoading: Bool
    /// A launchctl command the user asked for is still running.
    public var actionInFlight: Bool
    /// Consecutive polls that found nothing answering.
    public var offlineStreak: Int
    /// Inside the fast-poll window that follows a start or restart.
    public var isPollingFast: Bool

    public init(
        screen: DashboardScreen, isLoading: Bool = false, actionInFlight: Bool = false,
        offlineStreak: Int = 0, isPollingFast: Bool = false
    ) {
        self.screen = screen
        self.isLoading = isLoading
        self.actionInFlight = actionInFlight
        self.offlineStreak = offlineStreak
        self.isPollingFast = isPollingFast
    }
}

public enum HealthReaction: Equatable {
    case none
    case showUnreachable
    case loadDashboard

    /// The one place the app decides what a poll result does to the window. Every
    /// screen has an answer for every kind of result — a state with no branch is how a
    /// window gets stuck on a spinner.
    public static func to(_ health: ServerHealth, in state: WindowState) -> HealthReaction {
        switch health {
        case .offline:
            switch state.screen {
            case .dashboard:
                // One missed poll can be a busy server; two in a row is a server that left.
                return state.offlineStreak >= 2 ? .showUnreachable : .none
            case .unreachable:
                return .showUnreachable // redraw: the agent may have been fixed meanwhile
            case .starting:
                // A start gets its fast-poll window before it is called a failure.
                return state.isPollingFast || state.actionInFlight ? .none : .showUnreachable
            case .connecting:
                return .none // the load in flight reports its own failure
            }
        case .online, .unexpected:
            let idle = !state.isLoading && !state.actionInFlight
            return state.screen != .dashboard && idle ? .loadDashboard : .none
        }
    }
}
