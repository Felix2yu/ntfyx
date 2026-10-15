import Foundation

/// The one system scheduler primitive this app uses, behind a testable seam.
///
/// `NSBackgroundActivityScheduler` lets the OS run repeating maintenance — history
/// retention, cloud-config polling — when the machine is idle/asleep-efficient, instead
/// of keeping a private `Task.sleep` loop awake through App Nap. The OS invokes each
/// activity's handler on a background queue and does not schedule the next repetition
/// until the handler's completion is signalled, so every entry point hops to MainActor
/// and guarantees the `.finished` callback (audit F3).
@MainActor
public final class BackgroundTasks {
    public static let shared = BackgroundTasks()

    /// Well-known activity identifiers, prefixed with the app's bundle identifier.
    public enum Identifier {
        public static let historyRetention = AppConstants.bundleIdentifier + ".history-retention"
    }

    /// The OS-facing surface of one repeating activity. Exposed internal so tests can
    /// drive activities manually with a fake instead of waiting for system scheduling.
    private var activities: [String: SystemBackgroundActivityScheduling] = [:]

    /// Constructs the underlying scheduler; swapped for a fake in tests so no test ever
    /// registers a real system activity.
    private let makeScheduler: @MainActor (String) -> SystemBackgroundActivityScheduling

    public init() {
        makeScheduler = { NSBackgroundActivityScheduler(identifier: $0) }
    }

    /// Test-only initializer with a custom scheduler factory.
    init(makeScheduler: @escaping @MainActor (String) -> SystemBackgroundActivityScheduling) {
        self.makeScheduler = makeScheduler
    }

    /// Registers (or replaces) a repeating activity. A repeat registration under the
    /// same identifier first invalidates the previous one. `work` runs on MainActor;
    /// completion is always signalled when it returns.
    public func register(
        identifier: String,
        interval: TimeInterval,
        tolerance: TimeInterval = 0,
        qualityOfService: QualityOfService = .utility,
        work: @escaping @MainActor @Sendable () async -> Void
    ) {
        activities[identifier]?.invalidate()

        let scheduler = makeScheduler(identifier)
        scheduler.repeats = true
        scheduler.interval = interval
        scheduler.tolerance = tolerance
        scheduler.qualityOfService = qualityOfService

        scheduler.schedule { [weak self] completion in
            // Background-queue callback from the OS: only hop actors here.
            Task { @MainActor [weak self] in
                guard let self, self.activities[identifier] != nil else {
                    // A late callback after unregister/replace must not run the work.
                    completion(.finished)
                    return
                }
                // A repeating activity is never scheduled again until this runs.
                defer { completion(.finished) }
                await work()
            }
        }

        activities[identifier] = scheduler
    }

    /// Stops and forgets the named activity.
    public func unregister(identifier: String) {
        activities.removeValue(forKey: identifier)?.invalidate()
    }

    /// Whether the named activity is currently registered (test support).
    func isRegistered(identifier: String) -> Bool {
        activities[identifier] != nil
    }

    /// Stops every registered activity (test teardown).
    func invalidateAll() {
        activities.values.forEach { $0.invalidate() }
        activities.removeAll()
    }
}

/// The slice of `NSBackgroundActivityScheduler` `BackgroundTasks` depends on.
///
/// The schedule block receives the OS completion handler and must call it with a result
/// once the work is done. The real class conforms in an extension below; tests use a
/// hand-driven fake.
protocol SystemBackgroundActivityScheduling: AnyObject {
    var repeats: Bool { get set }
    var interval: TimeInterval { get set }
    var tolerance: TimeInterval { get set }
    var qualityOfService: QualityOfService { get set }
    func schedule(_ block: @escaping @Sendable (@escaping @Sendable (NSBackgroundActivityScheduler.Result) -> Void) -> Void)
    func invalidate()
}

extension NSBackgroundActivityScheduler: SystemBackgroundActivityScheduling {}
