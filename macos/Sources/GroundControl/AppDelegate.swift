import AppKit
import GroundControlCore

/// Wires the window, the server poll and the launchd agent together, and owns the menus.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let endpoint: ServerEndpoint
    /// Set when the `ServerURL` setting was refused; shown on the offline screen.
    private let endpointWarning: String?
    private let monitor: ServerMonitor
    private let agent = AgentController()
    private var dashboard: DashboardWindowController!
    private var lastFailure: String?
    private var lastAdvice: OfflineAdvice?
    private var logAvailable = false
    private var inspecting = false
    private var actionInFlight = false

    override init() {
        let resolved = ServerEndpoint.resolve(
            UserDefaults.standard.string(forKey: ServerEndpoint.settingKey))
        endpoint = resolved.endpoint
        endpointWarning = resolved.warning
        if let warning = resolved.warning { NSLog("Ground Control: %@", warning) }
        monitor = ServerMonitor(endpoint: endpoint)
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(delegate: self)

        dashboard = DashboardWindowController(endpoint: endpoint)
        dashboard.offlineView.onAction = { [weak self] action in self?.perform(action) }
        dashboard.offlineView.onRetry = { [weak self] in self?.retry() }
        dashboard.offlineView.onShowLog = { [weak self] in self?.showServerLog(nil) }
        dashboard.onLoadFailed = { [weak self] reason in self?.dashboardFailed(reason) }
        dashboard.loadDashboard()
        dashboard.showWindow(nil)

        monitor.onUpdate = { [weak self] health in self?.healthChanged(health) }
        monitor.start()

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        // A setting the user wrote on purpose must not be ignored quietly — least of all
        // when the standard address happens to work and nothing else would look wrong.
        if let endpointWarning {
            showError("Ignored the \(ServerEndpoint.settingKey) setting", endpointWarning)
        }
    }

    /// The app outlives its window: the Dock badge keeps counting alerts, and clicking
    /// the icon brings the same page back without reloading it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { dashboard.showWindow(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for (index, tab) in DashboardTab.allCases.enumerated() {
            let item = menu.addItem(withTitle: tab.title, action: #selector(showTab(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Restart Server", action: #selector(restartServer(_:)), keyEquivalent: "")
            .target = self
        return menu
    }

    // MARK: - Server health

    private func healthChanged(_ health: ServerHealth) {
        NSApp.dockTile.badgeLabel = health.badgeLabel
        if case .offline(let reason) = health { lastFailure = reason }
        let state = WindowState(
            screen: dashboard.screen, isLoading: dashboard.isLoading, actionInFlight: actionInFlight,
            offlineStreak: monitor.offlineStreak, isPollingFast: monitor.isPollingFast)
        switch HealthReaction.to(health, in: state) {
        case .none: break
        case .showUnreachable: showUnreachable()
        case .loadDashboard: dashboard.loadDashboard()
        }
    }

    private func dashboardFailed(_ reason: String) {
        lastFailure = reason
        showUnreachable()
        monitor.pollNow() // the badge should say "off" now, not on the next 30 s tick
    }

    private func retry() {
        dashboard.loadDashboard()
        monitor.pollNow()
    }

    private func showUnreachable() {
        dashboard.showUnreachable(
            reason: lastFailure, advice: lastAdvice, note: endpointNote, logAvailable: logAvailable)
        refreshAdvice()
    }

    /// Asks launchd where the agent stands, then redraws the offline screen with advice
    /// that matches (install it / start it / restart it / fix the port).
    private func refreshAdvice() {
        guard !inspecting else { return }
        inspecting = true
        Task {
            let install = await agent.inspect()
            let plist = agent.installedPlist()
            inspecting = false
            lastAdvice = install.advice(endpoint: endpoint, agentPort: plist?.port)
            logAvailable = plist?.logPath != nil
            if dashboard.screen == .unreachable {
                dashboard.showUnreachable(
                    reason: lastFailure, advice: lastAdvice, note: endpointNote,
                    logAvailable: logAvailable)
            }
        }
    }

    private var endpointNote: String? {
        if let endpointWarning { return endpointWarning }
        if !endpoint.isStandard {
            return "Using the \(ServerEndpoint.settingKey) setting: http://\(endpoint.authority)"
        }
        return nil
    }

    private func perform(_ action: ServerAction) {
        if action == .openSetupGuide {
            NSWorkspace.shared.open(ProjectLinks.setupGuide)
            return
        }
        guard !actionInFlight else { return }
        actionInFlight = true
        dashboard.showStarting(action == .restart ? "Restarting the server\u{2026}" : "Starting the server\u{2026}")
        dashboard.showWindow(nil)
        Task {
            let failure = await agent.perform(action)
            actionInFlight = false
            if let failure {
                lastFailure = failure
                showUnreachable()
                showError("The server didn\u{2019}t start", failure)
            } else {
                monitor.pollFast()
            }
        }
    }

    private func showError(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        if let window = dashboard.window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Menu actions

    @objc func showTab(_ sender: NSMenuItem) {
        guard DashboardTab.allCases.indices.contains(sender.tag) else { return }
        dashboard.showWindow(nil)
        dashboard.select(DashboardTab.allCases[sender.tag])
    }

    @objc func reloadDashboard(_ sender: Any?) { retry() }

    @objc func zoomIn(_ sender: Any?) { dashboard.zoom(by: 1.1) }
    @objc func zoomOut(_ sender: Any?) { dashboard.zoom(by: 1 / 1.1) }
    @objc func actualSize(_ sender: Any?) { dashboard.zoom(by: nil) }

    @objc func openInBrowser(_ sender: Any?) { NSWorkspace.shared.open(dashboard.browserURL) }

    @objc func openRepository(_ sender: Any?) { NSWorkspace.shared.open(ProjectLinks.repository) }

    @objc func restartServer(_ sender: Any?) {
        Task {
            switch await agent.inspect() {
            case .loaded(let snapshot): perform(snapshot.pid == nil ? .start : .restart)
            case .installedNotLoaded: perform(.load)
            case .notInstalled:
                let alert = NSAlert()
                alert.messageText = "The server agent isn\u{2019}t installed"
                alert.informativeText = "Ground Control can start and restart \(ServerAgent.label) "
                    + "once it is installed. If you run the server with ./run.sh instead, "
                    + "restart it there."
                alert.addButton(withTitle: "Open Setup Guide")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(ProjectLinks.setupGuide)
                }
            }
        }
    }

    /// Opens the agent's log in Console. The path comes from the installed plist, and
    /// the file goes to Console specifically, never to whatever app claims its type.
    @objc func showServerLog(_ sender: Any?) {
        guard let path = agent.installedPlist()?.logPath else {
            showError("No server log", "The installed agent plist names no StandardOutPath.")
            return
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            showError("No server log yet", "\(url.path) doesn\u{2019}t exist yet.")
            return
        }
        guard let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console")
        else {
            showError("Console isn\u{2019}t available", url.path)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "A native window for the Ground Control dashboard at http://\(endpoint.authority).",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showTab(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)),
            #selector(actualSize(_:)):
            return dashboard?.screen == .dashboard
        case #selector(restartServer(_:)):
            return !actionInFlight
        default:
            return true
        }
    }
}
