import WebKit
import XCTest

@testable import GroundControl

/// WebKit and AppKit call these methods by Objective-C selector. If a Swift signature
/// stops matching the SDK's — a renamed label, a changed closure type on a new SDK — it
/// still compiles, and the system simply never calls it: links stop opening, dialogs
/// return false, a dead server shows a blank window. So check the selectors the system
/// actually sends, by their Objective-C names.
final class DelegateWiringTests: XCTestCase {
    func testTheWindowAnswersEveryWebKitCallItRelies() {
        let selectors = [
            "webView:decidePolicyForNavigationAction:decisionHandler:",
            "webView:didFinishNavigation:",
            "webView:didFailProvisionalNavigation:withError:",
            "webView:didFailNavigation:withError:",
            "webViewWebContentProcessDidTerminate:",
            "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:",
            "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
        ]
        for name in selectors {
            XCTAssertTrue(
                DashboardWindowController.instancesRespond(to: NSSelectorFromString(name)),
                "WebKit would never call \(name)")
        }
        XCTAssertFalse(
            DashboardWindowController.instancesRespond(to: NSSelectorFromString("webView:noSuchCall:")),
            "the check itself must be able to fail")
    }

    func testTheAppDelegateAnswersTheLifecycleCalls() {
        for name in [
            "applicationDidFinishLaunching:",
            "applicationShouldTerminateAfterLastWindowClosed:",
            "applicationShouldHandleReopen:hasVisibleWindows:",
            "applicationDockMenu:",
            "validateMenuItem:",
        ] {
            XCTAssertTrue(AppDelegate.instancesRespond(to: NSSelectorFromString(name)), name)
        }
    }
}
