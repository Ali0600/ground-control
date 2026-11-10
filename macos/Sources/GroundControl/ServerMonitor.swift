import Foundation
import GroundControlCore

/// Polls `GET /api/watch`. It drives the Dock badge, and tells the app when the server
/// goes away or comes back — the one failure the server cannot report about itself.
///
/// The route only reads the watcher's saved state (no `lsof` scan), so polling it costs
/// the server a file read.
@MainActor
final class ServerMonitor {
    /// While the server answers: the page's own refresh interval.
    static let steadyInterval: TimeInterval = 30
    /// While nothing answers: often enough that a recovery shows within seconds.
    static let offlineInterval: TimeInterval = 3
    /// Right after the app starts or restarts the server.
    static let fastInterval: TimeInterval = 1

    private(set) var health: ServerHealth?
    /// Consecutive polls that found nothing answering.
    private(set) var offlineStreak = 0
    var onUpdate: ((ServerHealth) -> Void)?

    var isPollingFast: Bool { Date() < fastUntil }

    private let url: URL
    private let session: URLSession
    private var timer: Timer?
    private var inFlight = false
    private var fastUntil = Date.distantPast

    init(endpoint: ServerEndpoint) {
        url = endpoint.watchURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    func start() { pollNow() }

    /// Poll every second for a while: after a start or restart, so the window comes
    /// back as soon as the server does.
    func pollFast(for seconds: TimeInterval = 30) {
        fastUntil = Date().addingTimeInterval(seconds)
        pollNow()
    }

    func pollNow() {
        timer?.invalidate()
        timer = nil
        // A poll already in flight reschedules itself at the current cadence when it
        // lands; cancelling it would turn a healthy answer into a fake "offline".
        guard !inFlight else { return }
        inFlight = true
        Task { [weak self] in
            guard let self else { return }
            let health = await self.fetch()
            self.finish(health)
        }
    }

    private func fetch() async -> ServerHealth {
        do {
            let (data, response) = try await session.data(from: url)
            return ServerHealth.classify(
                statusCode: (response as? HTTPURLResponse)?.statusCode, body: data, error: nil)
        } catch {
            return ServerHealth.classify(statusCode: nil, body: nil, error: error)
        }
    }

    private func finish(_ health: ServerHealth) {
        inFlight = false
        offlineStreak = health.isOnline ? 0 : offlineStreak + 1
        self.health = health
        onUpdate?(health)
        let interval: TimeInterval
        if !health.isOnline {
            interval = isPollingFast ? Self.fastInterval : Self.offlineInterval
        } else {
            interval = Self.steadyInterval
        }
        schedule(after: interval)
    }

    private func schedule(after interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.pollNow() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
