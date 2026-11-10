import GroundControlCore
import XCTest

@testable import GroundControl

/// The agent controls, stubbed at the subprocess boundary: what's tested is the argv sent
/// and how the exit status is read. No live launchctl, like the Python suite.
@MainActor
final class AgentControllerTests: XCTestCase {
    private var home: URL!
    private var calls: [[String]] = []
    private var replies: [Launchctl.Result] = []

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("gc-agent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/LaunchAgents"), withIntermediateDirectories: true)
        calls = []
        replies = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func controller() -> AgentController {
        AgentController(agent: ServerAgent(uid: 501, home: home)) { [unowned self] arguments in
            self.calls.append(arguments)
            return self.replies.isEmpty ? Launchctl.Result(status: 0, output: "") : self.replies.removeFirst()
        }
    }

    private func installPlist(port: Int = 8787) throws {
        let plist: [String: Any] = [
            "Label": ServerAgent.label,
            "ProgramArguments": ["/Users/dev/ground-control/.venv/bin/uvicorn", "app.main:app", "--port", "\(port)"],
            "StandardOutPath": "/Users/dev/ground-control/server.log",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: ServerAgent(uid: 501, home: home).plistURL)
    }

    func testInspectTrustsTheExitStatusThenThePlist() async throws {
        replies = [Launchctl.Result(status: 113, output: "Could not find service")]
        let missing = await controller().inspect()
        XCTAssertEqual(missing, .notInstalled)

        try installPlist()
        replies = [Launchctl.Result(status: 113, output: "Could not find service")]
        let unloaded = await controller().inspect()
        XCTAssertEqual(unloaded, .installedNotLoaded)

        replies = [Launchctl.Result(status: 0, output: "x = {\n\tstate = running\n\tpid = 7\n}")]
        let loaded = await controller().inspect()
        XCTAssertEqual(loaded, .loaded(AgentSnapshot(state: "running", pid: 7)))
        XCTAssertEqual(calls, Array(repeating: ["print", "gui/501/com.launchddash.server"], count: 3))
    }

    func testEachActionSendsItsCommand() async {
        let agentControl = controller()
        let restarted = await agentControl.perform(.restart)
        XCTAssertNil(restarted)
        let started = await agentControl.perform(.start)
        XCTAssertNil(started)
        let loaded = await agentControl.perform(.load)
        XCTAssertNil(loaded)
        let guide = await agentControl.perform(.openSetupGuide)
        XCTAssertNil(guide)
        XCTAssertEqual(calls, [
            ["kickstart", "-k", "gui/501/com.launchddash.server"],
            ["kickstart", "gui/501/com.launchddash.server"],
            ["bootstrap", "gui/501", home.appendingPathComponent(
                "Library/LaunchAgents/com.launchddash.server.plist").path],
        ], "the setup guide is a web page, not a command")
    }

    func testAFailedCommandSaysWhatFailedAndWhy() async throws {
        replies = [Launchctl.Result(status: 5, output: "Bootstrap failed: 5: Input/output error")]
        let failure = await controller().perform(.load)
        let message = try XCTUnwrap(failure)
        XCTAssertTrue(message.contains("exit 5"), message)
        XCTAssertTrue(message.contains("Input/output error"), message)
    }

    func testTheInstalledPlistNamesTheLogAndThePort() throws {
        XCTAssertNil(controller().installedPlist())
        try installPlist(port: 9001)
        let plist = try XCTUnwrap(controller().installedPlist())
        XCTAssertEqual(plist.port, 9001)
        XCTAssertEqual(plist.logPath, "/Users/dev/ground-control/server.log")
    }
}

/// The runner's own plumbing, on /bin/sh rather than launchctl.
final class LaunchctlRunnerTests: XCTestCase {
    private let sh = URL(fileURLWithPath: "/bin/sh")

    func testBothStreamsAndTheExitStatusComeBack() {
        let result = Launchctl.runBlocking(["-c", "echo out; echo err >&2; exit 3"], executable: sh)
        XCTAssertEqual(result.status, 3)
        XCTAssertTrue(result.output.contains("out") && result.output.contains("err"), result.output)
    }

    /// 200 KB through a pipe that holds 64 KB: the read must come before the wait, or the
    /// child blocks on a full pipe and the wait never returns.
    func testOutputBiggerThanThePipeDoesNotDeadlock() {
        let result = Launchctl.runBlocking(
            ["-c", "head -c 200000 /dev/zero | tr '\\0' x"], executable: sh, timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, 200_000)
    }

    func testAHungCommandIsStoppedByTheWatchdog() {
        let started = Date()
        let result = Launchctl.runBlocking(["-c", "exec sleep 30"], executable: sh, timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the watchdog never fired")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("did not finish"), result.output)
    }
}
