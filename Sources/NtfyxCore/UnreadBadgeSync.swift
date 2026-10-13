import Foundation
import Observation

/// Keeps the menu bar unread badge in sync with the history store: computes the total
/// once at startup, then recomputes on every store change (new message, read here or
/// on another device, delete). Without the startup pass the badge stayed at zero until
/// the next live message arrived, even with thousands of unreads in the database.
///
/// Audit B3: changes arrive on the typed `HistoryChangeBus` (no more NotificationCenter
/// broadcast); a burst is still coalesced into one scan by cancelling and restarting a
/// Task-based settle window instead of a `Timer`.
@MainActor
@Observable
final class UnreadBadgeSync {
    /// A burst of messages posts one store change each, but the badge only shows the settled
    /// total, and every recompute scans the unread index.
    static let settleTime: TimeInterval = 0.25

    private let store: MessageStore
    private let bus: HistoryChangeBus
    private let setCount: @MainActor (Int) -> Void
    private var streamTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?

    init(store: MessageStore,
         bus: HistoryChangeBus = .shared,
         setCount: @escaping @MainActor (Int) -> Void) {
        self.store = store
        self.bus = bus
        self.setCount = setCount
    }

    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.bus.changes() {
                self.scheduleRefresh()
            }
        }
        Task { await refresh() }
    }

    func stop() {
        settleTask?.cancel()
        settleTask = nil
        streamTask?.cancel()
        streamTask = nil
    }

    /// Restarts the settle window, so a whole replay costs one scan instead of one per message.
    private func scheduleRefresh() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.settleTime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh() async {
        // The sidebar already needs this per-topic aggregate; summing it is cheaper than
        // a second full-table count for the badge alone.
        let counts = (try? await store.unreadCountsByTopic()) ?? [:]
        setCount(counts.values.reduce(0, +))
    }
}
