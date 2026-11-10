import Foundation

/// The page's five tabs, in its order — `const TABS` in `app/main.py`, pinned by
/// `RepoContractTests` so a tab added to the page cannot leave the View menu behind.
public enum DashboardTab: String, CaseIterable {
    case agents, apps, ports, watch, history

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// ⌘1 … ⌘5, in tab order.
    public var keyEquivalent: String {
        String((DashboardTab.allCases.firstIndex(of: self) ?? 0) + 1)
    }

    /// Switches the page by clicking its own tab button, so the switch takes the page's
    /// front door (`goTab`, which also fetches History when it becomes visible) rather
    /// than reimplementing it. The id is built from one of five constants, never from
    /// input. Evaluates to `false` when the button is missing, so a renamed id is
    /// reported instead of doing nothing.
    public var activationScript: String {
        "(() => { const t = document.getElementById(\"tab-\(rawValue)\"); "
            + "if (!t) return false; t.click(); return true; })()"
    }
}
