import Foundation
import GroundControlCore

/// Runs `/bin/launchctl` for the server agent.
///
/// Fixed argv, no shell: every argument comes from `ServerAgent`, which builds it from a
/// constant label, the uid and the home directory. Nothing the page says reaches here.
@MainActor
final class AgentController {
    typealias Runner = ([String]) async -> Launchctl.Result

    let agent: ServerAgent
    /// The subprocess boundary. Tests stub it here — the same seam the Python suite uses
    /// (`launchd._run`) — so the argv and the reading of the exit status are what's tested.
    private let run: Runner

    init(
        agent: ServerAgent = ServerAgent(uid: getuid(), home: FileManager.default.homeDirectoryForCurrentUser),
        run: @escaping Runner = Launchctl.run
    ) {
        self.agent = agent
        self.run = run
    }

    /// The installed plist, when there is a readable one.
    func installedPlist() -> AgentPlist? {
        guard let data = try? Data(contentsOf: agent.plistURL) else { return nil }
        return AgentPlist.parse(data)
    }

    func inspect() async -> AgentInstall {
        let result = await run(agent.printArguments)
        let plistExists = FileManager.default.fileExists(atPath: agent.plistURL.path)
        return AgentInstall.classify(
            printStatus: result.status, printOutput: result.output, plistExists: plistExists)
    }

    /// Runs the command for `action`. Returns `nil` on success, or what went wrong.
    func perform(_ action: ServerAction) async -> String? {
        guard let arguments = agent.arguments(for: action) else { return nil }
        let result = await run(arguments)
        if result.status == 0 { return nil }
        var message = "launchctl \(arguments.joined(separator: " ")) failed (exit \(result.status))"
        if !result.output.isEmpty { message += ": \(result.output)" }
        return message
    }
}

enum Launchctl {
    struct Result: Equatable {
        let status: Int32
        let output: String
    }

    /// An absolute path: a GUI app gets launchd's minimal PATH, not a shell's.
    static let executable = URL(fileURLWithPath: "/bin/launchctl")

    static func run(_ arguments: [String]) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(arguments))
            }
        }
    }

    /// stdout and stderr share ONE pipe, read to EOF before waiting: a child that fills an
    /// unread pipe blocks forever, and two pipes read one after the other can deadlock.
    /// A watchdog ends a launchctl that hangs, so a stuck call cannot wedge the button.
    /// `executable` is only ever changed by tests, which check this plumbing on /bin/sh.
    static func runBlocking(
        _ arguments: [String], executable: URL = Launchctl.executable, timeout: TimeInterval = 15
    ) -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "could not run launchctl: \(error.localizedDescription)")
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        var output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationReason == .uncaughtSignal {
            output = "\(executable.lastPathComponent) did not finish within \(timeout) s and was stopped. "
                + output
        }
        return Result(status: process.terminationStatus, output: output)
    }
}
