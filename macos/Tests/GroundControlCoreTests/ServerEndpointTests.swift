import XCTest

@testable import GroundControlCore

final class ServerEndpointTests: XCTestCase {
    func testNoSettingMeansTheStandardAddress() {
        for raw in [nil, "", "   ", "\n"] {
            let (endpoint, warning) = ServerEndpoint.resolve(raw)
            XCTAssertEqual(endpoint, .standard, "\(String(describing: raw))")
            XCTAssertNil(warning)
        }
        XCTAssertEqual(ServerEndpoint.standard.url.absoluteString, "http://127.0.0.1:8787/")
        XCTAssertEqual(ServerEndpoint.standard.watchURL.absoluteString, "http://127.0.0.1:8787/api/watch")
    }

    func testLoopbackOriginsAreAccepted() {
        let cases: [(String, String, Int)] = [
            ("http://127.0.0.1:9000", "127.0.0.1", 9000),
            ("http://localhost:8787/", "localhost", 8787),
            ("HTTP://LOCALHOST:8787", "localhost", 8787),
            ("  http://127.0.0.1:8787  ", "127.0.0.1", 8787),
            ("http://[::1]:8787", "::1", 8787),
            ("http://localhost", "localhost", 80),
        ]
        for (raw, host, port) in cases {
            let (endpoint, warning) = ServerEndpoint.resolve(raw)
            XCTAssertNil(warning, raw)
            XCTAssertEqual(endpoint.host, host, raw)
            XCTAssertEqual(endpoint.port, port, raw)
        }
    }

    func testIPv6NeedsBracketsInTheAddress() {
        let endpoint = ServerEndpoint(host: "::1", port: 8787)
        XCTAssertEqual(endpoint.authority, "[::1]:8787")
        XCTAssertEqual(endpoint.url.absoluteString, "http://[::1]:8787/")
        XCTAssertEqual(ServerEndpoint(host: "[::1]", port: 8787), endpoint, "brackets are normalised away")
    }

    /// Each refusal falls back to the standard address AND says why, quoting the value —
    /// a typo in the setting must be visible, not silently replaced.
    func testAnythingElseIsRefusedWithAReason() {
        let refused = [
            "http://192.0.2.10:8787",          // another machine
            "http://example.com:8787",
            "http://127.0.0.1.example.com:8787", // looks loopback, isn't
            "http://localhost.example.com",
            "http://127.0.0.2:8787",           // loopback range, but not a host the server accepts
            "https://127.0.0.1:8787",          // the server speaks plain http
            "ftp://127.0.0.1",
            "file:///tmp/x",
            "127.0.0.1:8787",                  // no scheme
            "localhost:8787",                  // parses as scheme "localhost" without the guard
            "http://user:pw@127.0.0.1:8787",
            "http://127.0.0.1:8787/api",
            "http://127.0.0.1:8787/?x=1",
            "http://127.0.0.1:8787/#ports",
            "http://127.0.0.1:0",
            "http://:8787",
            "not a url",
        ]
        for raw in refused {
            let (endpoint, warning) = ServerEndpoint.resolve(raw)
            XCTAssertEqual(endpoint, .standard, raw)
            let message = try? XCTUnwrap(warning, "no warning for \(raw)")
            XCTAssertTrue(message?.contains(raw) ?? false, "the warning should quote \(raw): \(message ?? "nil")")
        }
    }

    func testSameOriginIsExactSchemeHostAndPort() {
        let endpoint = ServerEndpoint.standard
        XCTAssertTrue(endpoint.isSameOrigin(URL(string: "http://127.0.0.1:8787/")!))
        XCTAssertTrue(endpoint.isSameOrigin(URL(string: "http://127.0.0.1:8787/api/watch?x=1#ports")!))
        XCTAssertTrue(endpoint.isSameOrigin(URL(string: "HTTP://127.0.0.1:8787/")!))
        XCTAssertFalse(endpoint.isSameOrigin(URL(string: "http://localhost:8787/")!), "same server, other origin")
        XCTAssertFalse(endpoint.isSameOrigin(URL(string: "http://127.0.0.1:8788/")!))
        XCTAssertFalse(endpoint.isSameOrigin(URL(string: "http://127.0.0.1/")!), "no port means 80")
        XCTAssertFalse(endpoint.isSameOrigin(URL(string: "https://127.0.0.1:8787/")!))
        XCTAssertTrue(
            ServerEndpoint(host: "::1", port: 8787).isSameOrigin(URL(string: "http://[::1]:8787/#watch")!))
    }
}
