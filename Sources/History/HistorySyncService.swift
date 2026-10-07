import Foundation

/// Orchestrates history synchronization between the server cache and the local store.
/// - Auto incremental sync: `since=<last synced message id>` (falls back to timestamp,
///   or a 90-day window on first sync) — triggered when a topic is opened.
/// - Manual full sync: `since=all` — user-initiated, with progress reporting.
/// Re-entrant calls for the same topic are ignored.
@MainActor
final class HistorySyncService: ObservableObject {

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

    @Published var progress: [TopicRef: SyncProgress] = [:]

    init(store: MessageStore) {
        self.store = store
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
            let since = try await resolveSince(ref: ref, full: full)
            Log.info("History sync \(full ? "(full)" : "(incremental)") for \(ref.topic)@\(ref.serverURL): since=\(since)")

            let token = ConfigManager.shared.getAuthToken(forServer: ref.serverURL)
            let store = self.store
            let result = try await poll(
                ref.serverURL,
                ref.topic,
                since,
                token,
                { events in
                    // One transaction per chunk, and one revoke call for however many banners
                    // the chunk's delete/clear events withdrew.
                    let revoked = try await store.applyBatch(events, serverURL: ref.serverURL)
                    if !revoked.isEmpty {
                        NotificationManager.shared.revoke(messageIDs: revoked)
                    }
                }
            )

            // Advance sync state to the newest message seen. The server replays `since`
            // in ascending time order, so action events land after their target message.
            if let newest = result.newestMessage {
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
                // window refreshes through the store-change notification instead.
                NotificationCenter.default.post(name: .historyStoreDidChange, object: nil, userInfo: ["topicRef": ref])
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

    /// Determines the `since` parameter for a sync run.
    private func resolveSince(ref: TopicRef, full: Bool) async throws -> String {
        if full {
            return "all"
        }
        if let info = try await store.latestSyncedInfo(serverURL: ref.serverURL, topic: ref.topic) {
            // Prefer message id (immune to clock skew); fall back to timestamp.
            if let id = info.id, !id.isEmpty {
                return id
            }
            if info.time > 0 {
                return String(info.time)
            }
        }
        // First sync: limit to a recent window instead of replaying the entire cache.
        let window: TimeInterval = 90 * 24 * 3600
        return String(Int(Date().timeIntervalSince1970 - window))
    }
}
