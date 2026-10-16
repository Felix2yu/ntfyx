import Foundation
import Combine

/// Owns every merge-and-converge pass off the main actor.
///
/// The facade (`ConfigSyncService`) only holds the UI-facing status; all blocking work —
/// iCloud `NSFileCoordinator` reads and writes (including waits for placeholder
/// downloads), YAML coding and Keychain access inside `ConfigSyncEngine.run` — happens on
/// this actor's executor or inside a detached utility task, so a slow cloud file can never
/// stall the UI (audit E1).
///
/// Status flows out through an `AsyncStream`; the facade bridges it into `@Published`.
actor ConfigSyncCoordinator {
    typealias Status = ConfigSyncService.Status

    /// Status events, oldest dropped when the UI cannot keep up.
    nonisolated let status: AsyncStream<Status>
    private nonisolated let statusContinuation: AsyncStream<Status>.Continuation

    /// Main-actor snapshot of the live configuration this Mac runs on.
    struct LocalSnapshot: Sendable {
        let config: AppConfig?
        /// Whether the active file is the default path — sync must never publish a
        /// `serve --config PATH` file as a machine's shared configuration.
        let isDefaultPath: Bool
    }

    let store = CloudConfigStore()
    private let localSnapshot: @Sendable @MainActor () -> LocalSnapshot
    private var state = SyncState(base: nil, lastSyncedAt: nil)
    private var pendingChange: Task<Void, Never>?
    private var isSyncing = false
    private var isRunning = false

    /// Event-driven cloud watching (NSMetadataQuery in iCloud Drive, directory events for
    /// custom folders / as a fallback). Owned only while sync is enabled.
    private var cloudObserver: CloudChangeObserver?
    private var cloudObserverTask: Task<Void, Never>?

    /// Both a hand-edit and a burst of cloud notifications land here; after the quiet
    /// period one merge covers the whole change.
    static let changeDebounce: TimeInterval = 2

    init(localSnapshot: @escaping @Sendable @MainActor () -> LocalSnapshot) {
        self.localSnapshot = localSnapshot
        var continuation: AsyncStream<Status>.Continuation!
        status = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation = $0 }
        statusContinuation = continuation
    }

    // MARK: - Settings

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppSettings.iCloudSyncEnabledKey)
    }

    private var directoryOverride: String {
        UserDefaults.standard.string(forKey: AppSettings.iCloudSyncDirectoryKey) ?? ""
    }

    // MARK: - Lifecycle

    /// Called once the service has a loaded configuration.
    func start() {
        guard isEnabled else {
            emit(.off)
            return
        }
        store.directoryOverride = directoryOverride.isEmpty ? nil : directoryOverride
        state = SyncStateStore.load()
        isRunning = true
        startCloudObserver()
        emit(.waiting)
        // The first merge still goes half a second in, letting the app finish launching
        // (and load its config) beforehand.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.synchronize()
        }
        Log.info("配置同步已开启：\(store.rootDirectory)")
    }

    func stop() {
        isRunning = false
        pendingChange?.cancel()
        pendingChange = nil
        stopCloudObserver()
    }

    /// A new sync folder has no agreed ancestor on this Mac; the merge starts over and the
    /// cloud observer re-subscribes to the new location.
    func resetDirectory(_ path: String) {
        store.directoryOverride = path.isEmpty ? nil : path
        state.base = nil
        SyncStateStore.save(state)
        guard isRunning else { return }
        stopCloudObserver()
        startCloudObserver()
    }

    // MARK: - Triggers

    /// ConfigWatcher's signal: the file on disk changed, so the cloud copy may need it.
    func noteLocalConfigChanged() {
        scheduleChange()
    }

    /// CloudChangeObserver's signal: the shared file or a conflict version moved; the
    /// observer has already coalesced the metadata burst, the actor-side debounce makes
    /// local+cloud edits share one merge.
    private func noteCloudChanged() {
        scheduleChange()
    }

    private func scheduleChange() {
        guard isEnabled else { return }
        pendingChange?.cancel()
        pendingChange = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.changeDebounce * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            await self?.synchronize()
        }
    }

    /// "立即同步" — ignores the debounce.
    func syncNow() {
        pendingChange?.cancel()
        Task { [weak self] in await self?.synchronize() }
    }

    // MARK: - Cloud observation

    private func startCloudObserver() {
        let observer = CloudChangeObserver(
            rootDirectory: store.rootDirectory,
            isICloud: store.usesICloudDrive
        )
        cloudObserver = observer
        cloudObserverTask = Task { [weak self] in
            for await _ in observer.changes {
                guard !Task.isCancelled else { return }
                await self?.noteCloudChanged()
            }
        }
        observer.start()
    }

    private func stopCloudObserver() {
        cloudObserverTask?.cancel()
        cloudObserverTask = nil
        cloudObserver?.stop()
        cloudObserver = nil
    }

    // MARK: - The cycle

    private func synchronize() async {
        guard isRunning, isEnabled, !isSyncing else { return }
        let snapshot = await localSnapshot()
        guard let local = snapshot.config else { return }
        guard snapshot.isDefaultPath else {
            // A `serve --config <PATH>` instance owns a file this feature was never meant
            // to publish; syncing it would push one machine's private config onto everyone.
            emit(.failed(L10n.format("配置同步只作用于默认配置文件 %@", ConfigFile.defaultConfigPath)))
            return
        }

        isSyncing = true
        emit(.syncing)
        // No ancestor yet means this Mac is joining: what it already has is its newest edit,
        // while everything only the cloud has is adopted as-is.
        let resolution: ConfigMerger.ConflictResolution =
            state.base == nil ? .preferLocal : .stableFingerprint
        let base = state.base ?? .empty
        let store = self.store

        do {
            // The blocking I/O (file coordination, placeholder downloads, Keychain) runs on
            // a detached utility task; the actor stays free for trigger/status calls.
            let outcome = try await Task.detached(priority: .utility) {
                try ConfigSyncEngine.run(
                    local: local, base: base, resolution: resolution, store: store
                )
            }.value

            if outcome.conflictCopiesMerged > 0 {
                Log.info("已合并并清理 \(outcome.conflictCopiesMerged) 个 iCloud 冲突副本")
            }
            if outcome.wroteLocal {
                Log.info("已按云端配置更新本地文件")
                // ConfigWatcher reloads the file, and the reloaded config is exactly the merged
                // document, so the debounced pass that follows writes nothing.
            }

            state.base = outcome.merged
            state.lastSyncedAt = Date()
            SyncStateStore.save(state)
            emit(.synced(state.lastSyncedAt ?? Date()))
            Log.info("配置同步完成：\(outcome.servers) 个服务器、\(outcome.topics) 个主题")
        } catch {
            // No retry timer: a still-present placeholder drives another metadata update
            // when it finishes downloading, and the user can always use "立即同步".
            let message = error.localizedDescription
            Log.error("配置同步失败：\(message)")
            emit(.failed(message))
        }
        isSyncing = false
    }

    private func emit(_ status: Status) {
        statusContinuation.yield(status)
    }
}
