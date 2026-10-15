import Foundation
import Observation

/// Orchestrates history synchronization between the server cache and the local store.
/// - Auto incremental sync: `since=<last synced event id>`, or this device's newest stored
///   row for a topic that was never polled (a 90-day window only when it has no rows at all)
///   — triggered when a topic is opened.
/// - Manual full sync: `since=all` — user-initiated, with progress reporting.
/// Re-entrant calls for the same topic are ignored.
@MainActor
@Observable
public final class HistorySyncService {

    enum SyncPhase: Equatable {
        case idle
        case syncing
        case rateLimited(retryAfter: TimeInterval)
        case failed(String)
        case completed(count: Int)
    }

    struct SyncProgress: Equatable {
        var phase: SyncPhase = .idle
        var receivedCount = 0
    }

    private let store: MessageStore
    private let changeBus: HistoryChangeBus
    private let configStore: ConfigStore
    private var syncingTopics: Set<TopicRef> = []
    private var scheduledRetries: [TopicRef: Task<Void, Never>] = [:]
    private var rateLimitAttempts: [TopicRef: Int] = [:]

    /// Network seam so tests can script failures without a live server.
    var poll: @Sendable (
        _ serverURL: String, _ topic: String, _ since: String, _ authToken: String?,
        _ onEvents: @escaping @Sendable ([NtfyMessage]) async throws -> Void
    ) async throws -> NtfyPollClient.PollResult = NtfyPollClient.poll

    /// audit 2.5: a rate-limited sync retries on its own once the window lapses.
    static let autoRetryLimit = 2
    static let maxAutoRetryDelay: TimeInterval = 300

    var progress: [TopicRef: SyncProgress] = [:]

    init(store: MessageStore, changeBus: HistoryChangeBus = .shared, configStore: ConfigStore = .shared) {
        self.store = store
        self.changeBus = changeBus
        self.configStore = configStore
    }

    public convenience init(store: MessageStore) {
        self.init(store: store, changeBus: .shared, configStore: .shared)
    }

    /// Whether a topic sync is currently running.
    func isSyncing(_ ref: TopicRef) -> Bool {
        syncingTopics.contains(ref)
    }

    func progress(for ref: TopicRef) -> SyncProgress {
        progress[ref] ?? SyncProgress()
    }

    /// Incremental sync — called when a topic is selected in the history window.
    func syncIncremental(_ ref: TopicRef) async {
        await sync(ref, full: false)
    }

    /// Full history sync (`since=all`) — user-initiated.
    func syncFull(_ ref: TopicRef) async {
        await sync(ref, full: true)
    }

    /// Cancels any pending auto-retry and starts the sync fresh.
    private func cancelScheduledRetry(_ ref: TopicRef) {
        scheduledRetries[ref]?.cancel()
        scheduledRetries[ref] = nil
    }

    private func scheduleAutoRetry(_ ref: TopicRef, after delay: TimeInterval) {
        cancelScheduledRetry(ref)
        let bounded = min(max(delay, 1.0), Self.maxAutoRetryDelay)
        scheduledRetries[ref] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(bounded * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.sync(ref, full: false, autoRetry: true)
        }
    }

    private func sync(_ ref: TopicRef, full: Bool, autoRetry: Bool = false) async {
        if autoRetry {
            guard (rateLimitAttempts[ref] ?? 0) < Self.autoRetryLimit else { return }
            rateLimitAttempts[ref] = (rateLimitAttempts[ref] ?? 0) + 1
        } else {
            cancelScheduledRetry(ref)
            rateLimitAttempts[ref] = 0
        }

        guard !syncingTopics.contains(ref) else { return }
        syncingTopics.insert(ref)
        defer { syncingTopics.remove(ref) }

        progress[ref] = SyncProgress(phase: .syncing, receivedCount: 0)

        do {
            let store = self.store
            // Snapshotted before the request: it is both where an incremental sync resumes and
            // what the replayed rows are classified against, and it must not move while they land.
            let frontier = (try? await store.maxStoredMessageTime(
                serverURL: ref.serverURL, topic: ref.topic
            )) ?? 0
            let since = try await resolveSince(ref: ref, full: full, frontier: frontier)
            Log.info("History sync \(full ? "(full)" : "(incremental)") for \(ref.topic)@\(ref.serverURL): since=\(since)")

            let token = configStore.authToken(forServer: ref.serverURL)
            let result = try await poll(
                ref.serverURL,
                ref.topic,
                since,
                token,
                { @Sendable events in
                    // One transaction per chunk, and one revoke call for however many banners
                    // the chunk's delete/clear events withdrew. The callback runs on the
                    // poll client's actor, so the main-actor notification path is hopped to.
                    let revoked = try await store.applyBatch(
                        events, serverURL: ref.serverURL, readNotNewerThan: frontier
                    )
                    if !revoked.isEmpty {
                        await MainActor.run {
                            NotificationManager.shared.revoke(messageIDs: revoked)
                        }
                    }
                }
            )

            // Advance sync state past the newest event, action events included. `since=<id>` is
            // exclusive, so a cursor that only counts messages leaves the clear/delete events
            // behind it to be replayed on every topic open — re-marking messages already read.
            if let newest = result.newestEvent {
                try await store.setSyncedInfo(
                    serverURL: ref.serverURL, topic: ref.topic,
                    id: newest.id, time: newest.time
                )
            }

            Log.info("History sync done for \(ref.topic): \(result.messageCount) messages, \(result.actionEventCount) action events")
            progress[ref] = SyncProgress(phase: .completed(count: result.messageCount), receivedCount: result.messageCount)
            rateLimitAttempts[ref] = 0
            cancelScheduledRetry(ref)
            if result.messageCount > 0 || result.actionEventCount > 0 {
                // Background retries have no UI path to trigger a reload; the open
                // window refreshes through the store-change bus instead.
                changeBus.post(topicRef: ref)
            }
        } catch let error as NtfyPollClient.PollError {
            if let retryAfter = error.retryAfter {
                Log.error("History sync rate limited for \(ref.topic): retry after \(Int(retryAfter))s")
                progress[ref] = SyncProgress(phase: .rateLimited(retryAfter: retryAfter), receivedCount: progress[ref]?.receivedCount ?? 0)
                scheduleAutoRetry(ref, after: retryAfter)
            } else {
                Log.error("History sync failed for \(ref.topic): \(error.localizedDescription)")
                progress[ref] = SyncProgress(phase: .failed(error.localizedDescription), receivedCount: 0)
            }
        } catch {
            Log.error("History sync failed for \(ref.topic): \(error)")
            progress[ref] = SyncProgress(phase: .failed(error.localizedDescription), receivedCount: 0)
        }
    }

    /// Determines the `since` parameter for a sync run, against the newest row this device has.
    private func resolveSince(ref: TopicRef, full: Bool, frontier: Int) async throws -> String {
        if full {
            return "all"
        }
        if let info = try await store.latestSyncedInfo(serverURL: ref.serverURL, topic: ref.topic),
           let id = info.id, !id.isEmpty {
            // Prefer message id (immune to clock skew).
            return id
        }
        // A topic that was never polled must not reach back for a fixed window either: this
        // server keeps months of cache, and everything in it older than the newest row here was
        // already gone through — replaying it lights up the unread badge on a plain open.
        // Resume at this device's own frontier instead (`since=<time>` includes it).
        if frontier > 0 {
            return String(frontier)
        }
        // A brand-new subscription has no local row at all: a recent window, not the whole cache.
        let window: TimeInterval = 90 * 24 * 3600
        return String(Int(Date().timeIntervalSince1970 - window))
    }
}
