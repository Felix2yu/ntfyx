import Foundation

/// Typed multicast channel for "the history store changed" events (audit B3), replacing
/// the old weakly-typed `Notification.Name.historyStoreDidChange` broadcast.
///
/// A change names the affected topic; a `nil` topic means the change can affect anything
/// (retention pass, whole-store edit). Consumers (the history view model, the unread-badge
/// syncer) coalesce bursts on their own instead of polling.
@MainActor
final class HistoryChangeBus {
    static let shared = HistoryChangeBus()

    struct Change: Equatable {
        let topicRef: TopicRef?
        /// Only the unread counts moved — the rows themselves still show the same content, so
        /// the list keeps its items and scroll position and just the sidebar and badge refresh.
        let countsOnly: Bool

        init(topicRef: TopicRef?, countsOnly: Bool = false) {
            self.topicRef = topicRef
            self.countsOnly = countsOnly
        }
    }

    private var continuations: [UUID: AsyncStream<Change>.Continuation] = [:]

    init() {}

    /// Returns a fresh multicast stream. Termination unregisters the consumer
    /// automatically, so a released view model cannot receive changes.
    func changes() -> AsyncStream<Change> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.continuations[id] = nil
                }
            }
        }
    }

    func post(topicRef: TopicRef?, countsOnly: Bool = false) {
        let change = Change(topicRef: topicRef, countsOnly: countsOnly)
        for continuation in continuations.values {
            continuation.yield(change)
        }
    }
}
