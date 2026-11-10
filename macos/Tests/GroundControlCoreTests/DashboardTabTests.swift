import JavaScriptCore
import XCTest

@testable import GroundControlCore

final class DashboardTabTests: XCTestCase {
    func testTitlesAndShortcutsFollowTabOrder() {
        XCTAssertEqual(DashboardTab.allCases.map(\.title), ["Agents", "Apps", "Ports", "Watch", "History"])
        XCTAssertEqual(DashboardTab.allCases.map(\.keyEquivalent), ["1", "2", "3", "4", "5"])
    }

    /// Runs the real script against a stub document rather than grepping it: it must
    /// click exactly the button for its tab, and report a missing one as `false`.
    func testTheActivationScriptClicksThePagesOwnButton() throws {
        for tab in DashboardTab.allCases {
            let js = try XCTUnwrap(JSContext())
            js.evaluateScript("""
                var clicked = [];
                var document = { getElementById: function (id) {
                  return id.indexOf("tab-") === 0 ? { click: function () { clicked.push(id); } } : null;
                } };
                """)
            let result = js.evaluateScript(tab.activationScript)
            XCTAssertNil(js.exception, "\(tab): \(String(describing: js.exception))")
            XCTAssertEqual(result?.toBool(), true, "\(tab)")
            XCTAssertEqual(js.evaluateScript("clicked.join(',')")?.toString(), "tab-\(tab.rawValue)")

            js.evaluateScript("document.getElementById = function () { return null; };")
            XCTAssertEqual(js.evaluateScript(tab.activationScript)?.toBool(), false, "a missing button is reported")
        }
    }
}
