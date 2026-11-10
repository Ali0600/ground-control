import XCTest

@testable import GroundControlCore

final class ServerAgentTests: XCTestCase {
    private let agent = ServerAgent(uid: 501, home: URL(fileURLWithPath: "/Users/dev"))

    func testLaunchctlArguments() {
        XCTAssertEqual(agent.plistURL.path, "/Users/dev/Library/LaunchAgents/com.launchddash.server.plist")
        XCTAssertEqual(agent.printArguments, ["print", "gui/501/com.launchddash.server"])
        XCTAssertEqual(agent.arguments(for: .start), ["kickstart", "gui/501/com.launchddash.server"])
        XCTAssertEqual(
            agent.arguments(for: .restart), ["kickstart", "-k", "gui/501/com.launchddash.server"])
        XCTAssertEqual(
            agent.arguments(for: .load),
            ["bootstrap", "gui/501", "/Users/dev/Library/LaunchAgents/com.launchddash.server.plist"])
        XCTAssertNil(agent.arguments(for: .openSetupGuide))
    }

    // `launchctl print` for a running agent, trimmed. The nested blocks repeat `state = …`
    // about something else; only the service's own (one-tab) fields count.
    static let running = """
        gui/501/com.launchddash.server = {
        \tactive count = 1
        \tpath = /Users/dev/Library/LaunchAgents/com.launchddash.server.plist
        \ttype = LaunchAgent
        \tstate = running

        \tprogram = /Users/dev/ground-control/.venv/bin/uvicorn
        \targuments = {
        \t\t/Users/dev/ground-control/.venv/bin/uvicorn
        \t\t--port
        \t\t8787
        \t}

        \tstdout path = /Users/dev/ground-control/server.log
        \tpid = 38464
        \tlast exit code = (never exited)

        \tresource coalition = {
        \t\tID = 207342
        \t\tstate = active
        \t}
        }
        """

    static let crashed = """
        gui/501/com.launchddash.server = {
        \tstate = not running
        \tlast exit code = 1
        \tspawn type = daemon (3)
        \tjetsam coalition = {
        \t\tstate = active
        \t\tpid = 99
        \t}
        }
        """

    func testSnapshotReadsOnlyTheServicesOwnFields() {
        XCTAssertEqual(
            AgentSnapshot.parse(launchctlPrint: Self.running),
            AgentSnapshot(state: "running", pid: 38464, lastExitCode: "(never exited)"))
        XCTAssertEqual(
            AgentSnapshot.parse(launchctlPrint: Self.crashed),
            AgentSnapshot(state: "not running", pid: nil, lastExitCode: "1"),
            "a nested `pid = 99` belongs to the coalition, not the agent")
        XCTAssertEqual(AgentSnapshot.parse(launchctlPrint: ""), AgentSnapshot())
        XCTAssertNil(AgentSnapshot.parse(launchctlPrint: "x = {\n\tpid = soon\n}").pid)
    }

    func testInstallStateComesFromTheExitStatusNotTheText() {
        XCTAssertEqual(
            AgentInstall.classify(printStatus: 0, printOutput: Self.running, plistExists: false),
            .loaded(AgentSnapshot(state: "running", pid: 38464, lastExitCode: "(never exited)")))
        XCTAssertEqual(
            AgentInstall.classify(printStatus: 113, printOutput: "", plistExists: true),
            .installedNotLoaded)
        XCTAssertEqual(
            AgentInstall.classify(printStatus: 113, printOutput: Self.running, plistExists: false),
            .notInstalled, "text that looks like a running agent cannot outvote the exit status")
    }

    func testAdviceOffersTheCommandThatWouldHelp() {
        let endpoint = ServerEndpoint.standard
        XCTAssertEqual(AgentInstall.notInstalled.advice(endpoint: endpoint, agentPort: nil).action, .openSetupGuide)
        XCTAssertEqual(AgentInstall.installedNotLoaded.advice(endpoint: endpoint, agentPort: 8787).action, .load)

        let stuck = AgentInstall.loaded(AgentSnapshot(state: "running", pid: 4242))
            .advice(endpoint: endpoint, agentPort: 8787)
        XCTAssertEqual(stuck.action, .restart)
        XCTAssertTrue(stuck.detail.contains("4242"), stuck.detail)

        let crashed = AgentInstall.loaded(AgentSnapshot(state: "not running", lastExitCode: "1"))
            .advice(endpoint: endpoint, agentPort: nil)
        XCTAssertEqual(crashed.action, .start)
        XCTAssertTrue(crashed.detail.contains("code 1"), crashed.detail)

        let neverRan = AgentInstall.loaded(AgentSnapshot(lastExitCode: "(never exited)"))
            .advice(endpoint: endpoint, agentPort: nil)
        XCTAssertFalse(neverRan.detail.contains("code"), "a placeholder is not an exit code: \(neverRan.detail)")
    }

    /// Restarting an agent that serves another port would change nothing.
    func testAPortMismatchIsNamedInsteadOfOfferingARestart() {
        let advice = AgentInstall.loaded(AgentSnapshot(state: "running", pid: 7))
            .advice(endpoint: .standard, agentPort: 9000)
        XCTAssertNil(advice.action)
        XCTAssertTrue(advice.detail.contains("9000") && advice.detail.contains("8787"), advice.detail)
    }

    func testPlistParsing() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>com.launchddash.server</string>
              <key>ProgramArguments</key><array>
                <string>/Users/dev/ground-control/.venv/bin/uvicorn</string>
                <string>app.main:app</string>
                <string>--port=9001</string>
              </array>
              <key>StandardErrorPath</key><string>/Users/dev/ground-control/server.err</string>
            </dict></plist>
            """
        let plist = try XCTUnwrap(AgentPlist.parse(Data(xml.utf8)))
        XCTAssertEqual(plist.label, "com.launchddash.server")
        XCTAssertEqual(plist.port, 9001, "the --port=N spelling counts too")
        XCTAssertEqual(plist.logPath, "/Users/dev/ground-control/server.err", "stderr when there is no stdout path")
        XCTAssertNil(AgentPlist.parse(Data("not a plist".utf8)))
    }
}
