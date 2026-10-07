import Foundation

/// Keeps the menu bar unread badge in sync with the history store: computes the total
/// once at startup, then recomputes on every store change (new message, read here or
/// on another device, delete). Without the startup pass the badge stayed at zero until
/// the next live message arrived, even with thousands of unreads in the database.
@MainActor
final class UnreadBadgeSync: @unchecked Sendable {
    /// A burst of messages posts one store change each, but the badge only shows the settled
    /// total, and every recompute scans the unread index.
    static let settleTime: TimeInterval = 0.25

    private let store: MessageStore
    private let setCount: @MainActor (Int) -> Void
    private var observer: NSObjectProtocol?
    private var settleTimer: Timer?

    init(store: MessageStore, setCount: @escaping @MainActor (Int) -> Void) {
        self.store = store
        self.setCount = setCount
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .historyStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        refresh()
    }

    func stop() {
        settleTimer?.invalidate()
        settleTimer = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    /// Restarts the settle window, so a whole replay costs one scan instead of one per message.
    private func scheduleRefresh() {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(
            withTimeInterval: Self.settleTime, repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        let store = self.store
        Task { @MainActor in
            // The sidebar already needs this per-topic aggregate; summing it is cheaper than
            // a second full-table count for the badge alone.
            let counts = (try? await store.unreadCountsByTopic()) ?? [:]
            setCount(counts.values.reduce(0, +))
        }
    }
}
