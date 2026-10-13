import Foundation

/// Runs the daily history trim once per calendar day (audit 2.4/F3).
///
/// The OS schedules the repeating activity at an energy-friendly time, so a long-running
/// service gets trimmed every day even without a relaunch; the UserDefaults same-day gate
/// stays as the idempotent backstop (launch-time run, config reloads and the system fire
/// can all land on the same day). The trim itself — bounded `enforceRetention`, VACUUM
/// only when rows were actually removed, a wildcard change-bus post — is unchanged.
@MainActor
final class HistoryRetentionScheduler {
    static let lastRunDefaultsKey = "historyLastRetentionRun"
    static let dailyInterval: TimeInterval = 24 * 60 * 60
    static let dailyTolerance: TimeInterval = 6 * 60 * 60

    private let store: MessageStore
    private let bus: HistoryChangeBus
    private let defaults: UserDefaults
    private let backgroundTasks: BackgroundTasks
    private let now: @Sendable () -> Date
    private let identifier: String

    init(
        store: MessageStore,
        bus: HistoryChangeBus = .shared,
        defaults: UserDefaults = .standard,
        backgroundTasks: BackgroundTasks = .shared,
        now: @escaping @Sendable () -> Date = Date.init,
        identifier: String = BackgroundTasks.Identifier.historyRetention
    ) {
        self.store = store
        self.bus = bus
        self.defaults = defaults
        self.backgroundTasks = backgroundTasks
        self.now = now
        self.identifier = identifier
    }

    /// Registers the daily system activity and runs one gate-checked pass immediately,
    /// preserving the old launch-time behavior.
    func start() {
        backgroundTasks.register(
            identifier: identifier,
            interval: Self.dailyInterval,
            tolerance: Self.dailyTolerance
        ) { [weak self] in
            await self?.runIfDue()
        }
        Task { await runIfDue() }
    }

    /// Stops the system activity (tests and teardown).
    func stop() {
        backgroundTasks.unregister(identifier: identifier)
    }

    /// Trims expired history when no pass has run yet today.
    func runIfDue() async {
        let now = now()
        if let last = defaults.object(forKey: Self.lastRunDefaultsKey) as? TimeInterval,
           Calendar.current.isDate(Date(timeIntervalSince1970: last), inSameDayAs: now) {
            return
        }
        // Stamp before the work, exactly as the previous launch Task did; the error
        // branch only logs, so same-day retries stay gated by this timestamp.
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastRunDefaultsKey)
        do {
            let deleted = try await store.enforceRetention()
            guard deleted > 0 else { return }
            try await store.vacuum()
            Log.info("History retention: removed \(deleted) expired rows")
            bus.post(topicRef: nil)
        } catch {
            Log.error("History retention failed: \(error)")
        }
    }
}
