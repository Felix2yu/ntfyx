import Foundation
import UserNotifications
import AppKit

/// App constants
public enum AppConstants {
    public static let bundleIdentifier = "com.laurentftech.ntfyx"

    /// Returns the bundle identifier, falling back to hardcoded value if running via symlink
    public static var effectiveBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? bundleIdentifier
    }

    /// Returns the app version from Info.plist
    public static var effectiveVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

/// Reports a fatal startup problem. A double-clicked app has no terminal to write to,
/// so it reports through an alert instead.
@MainActor
private func fatalStartup(_ message: String, details: String? = nil) -> Never {
    if AppMode.isDockApp {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = details ?? ""
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    } else {
        print(message)
        if let details { print(details) }
    }
    exit(1)
}

/// Connection-relevant identity of one NtfyClient (audit 2.2). Two configs that
/// produce the same specs keep their connections alive; everything outside the spec
/// (silent flags, icons, scripts, actions) must not force a reconnect.
struct ClientSpec: Hashable {
    let serverURL: String
    let fetchMissed: Bool
    let topics: [String]      // sorted — order carries no meaning for the subscription
    let authToken: String?
}

/// What a replayed catch-up leaves behind for its banner decision, per server: the totals a
/// summary needs, plus at most `Ntfyx.catchUpIndividualBannerLimit` messages for the case
/// where the "replay" was really a handful. Keeping every replayed message — tens of thousands
/// of decoded rows for a busy server — was memory with no consumer.
struct CatchUpTally {
    var count = 0
    var topics: Set<String> = []
    var entries: [NtfyMessage] = []

    mutating func add(_ message: NtfyMessage) {
        count += 1
        topics.insert(message.topic)
        if entries.count < Ntfyx.catchUpIndividualBannerLimit {
            entries.append(message)
        }
    }
}

/// App-layer hooks the core coordinator cannot own (audit A1 target split: the GUI
/// executable owns the running coordinator, while core views may ask for a reload).
@MainActor
public enum AppHooks {
    /// Bound by the app target to the live coordinator's `reloadConfig()`.
    public static var reloadConfig: (() -> Void)?

    /// Bound by the app target to the SwiftUI permission-prompt window. Returns whether
    /// notification authorization ended up granted. Unbound callers (e.g. library users)
    /// are treated as an immediate denial.
    public static var requestNotificationPermission: (() async -> Bool)?
}

/// Main-actor coordinator: owns the live SSE clients and turns their event streams into
/// notifications, history rows and menu-bar state (audit B1 — formerly `@unchecked Sendable`
/// with delegate callbacks hopping to main; the hop is now the actor boundary itself).
@MainActor
public final class Ntfyx {
    /// UI-facing state, injected by the app composition root (audit B2).
    private let connections: ConnectionRegistry
    /// In-memory configuration source of truth (audit E3).
    private let configStore: ConfigStore
    /// Cloud config sync facade (audit B2/E3).
    private let configSync: ConfigSyncService
    /// OS-scheduled background activities (audit F3).
    private let backgroundTasks: BackgroundTasks
    /// Typed store-change channel (audit B3).
    private let changeBus = HistoryChangeBus.shared

    private var clientBySpec: [ClientSpec: NtfyClient] = [:]
    private var eventTaskBySpec: [ClientSpec: Task<Void, Never>] = [:]
    private var connectedSpecs: Set<ClientSpec> = []  // audit 2.6: per-connection state
    private var notificationManager: NotificationManager?
    private let scriptRunner = ScriptRunner()
    private var localServer: LocalNotificationServer?
    private var localServerPort: UInt16?
    private var messageStore: MessageStore?
    private var badgeSync: UnreadBadgeSync?
    private var historySync: HistorySyncService?
    /// Daily history trim; created together with the history store (audit F3).
    private var retentionScheduler: HistoryRetentionScheduler?
    /// The history scene keeps a single long-lived view model, created lazily the first
    /// time the window opens (the store itself opens during `serve()`).
    private var cachedHistoryViewModel: HistoryViewModel?

    /// Replayed (`since`) messages waiting for the replay to settle before their banners
    /// are decided, so a whole cached backlog costs one summary instead of thousands.
    private var pendingCatchUp: [String: CatchUpTally] = [:]
    private var catchUpBannerTimer: Timer?
    static let catchUpBannerSettleTime: TimeInterval = 1.5
    nonisolated static let catchUpIndividualBannerLimit = 3

    /// Set by serve() when this launch wrote the config file it then loaded: nothing is
    /// subscribed yet, so the UI should go straight to Settings.
    public private(set) var didCreateInitialConfig = false

    /// Builds the desired client specs from a config: one per (server, fetch_missed group).
    nonisolated static func clientSpecs(for config: AppConfig, authToken: (String) -> String?) -> [ClientSpec] {
        var specs: [ClientSpec] = []
        for server in config.servers {
            guard !server.topics.isEmpty else { continue }
            let token = authToken(server.url)
            let grouped = Dictionary(grouping: server.topics) {
                $0.fetchMissed ?? server.shouldFetchMissed
            }
            for (fetchMissed, topics) in grouped where !topics.isEmpty {
                specs.append(ClientSpec(
                    serverURL: server.url,
                    fetchMissed: fetchMissed,
                    topics: topics.map(\.name).sorted(),
                    authToken: token
                ))
            }
        }
        return specs
    }

    /// audit 2.6: a server split across several SSE connections (one per fetch_missed
    /// group) is shown connected only while every one of its connections is up —
    /// keying the menu bar on the URL alone let the callbacks overwrite each other.
    nonisolated static func serverConnected(serverURL: String, allSpecs: Set<ClientSpec>, connectedSpecs: Set<ClientSpec>) -> Bool {
        let forServer = allSpecs.filter { $0.serverURL == serverURL }
        return !forServer.isEmpty && forServer.isSubset(of: connectedSpecs)
    }

    public init(
        connections: ConnectionRegistry = .shared,
        configStore: ConfigStore = .shared,
        configSync: ConfigSyncService = .shared,
        backgroundTasks: BackgroundTasks = .shared
    ) {
        self.connections = connections
        self.configStore = configStore
        self.configSync = configSync
        self.backgroundTasks = backgroundTasks
        // Don't initialize notificationManager here - wait until it's needed
    }

    private func ensureNotificationManager() -> NotificationManager {
        if notificationManager == nil {
            let manager = NotificationManager.shared
            manager.setScriptRunner(scriptRunner)
            // Resolve notification link/action policy from the injected config only.
            manager.setConfigLookup(
                server: { [weak self] url in self?.configStore.serverConfig(forURL: url) },
                topic: { [weak self] url, topic in self?.configStore.topicConfig(serverURL: url, topic: topic) }
            )
            notificationManager = manager
        }
        return notificationManager!
    }

    /// Opens (or creates) the local history database and wires the history window.
    private func setupHistoryStore() {
        guard messageStore == nil else { return }
        do {
            let store = try MessageStore(dbPath: MessageStore.defaultDatabasePath)
            messageStore = store
            Task { @MainActor in
                let sync = HistorySyncService(store: store, configStore: self.configStore)
                self.historySync = sync
            }
            // Seed the badges from the database and keep them in sync afterwards.
            Task { @MainActor in
                let badgeSync = UnreadBadgeSync(store: store, bus: self.changeBus) { count in
                    self.connections.setUnreadCount(count)
                    NSApp.dockTile.badgeLabel = Self.dockBadgeLabel(count)
                }
                badgeSync.start()
                self.badgeSync = badgeSync
            }
            Log.info("History database opened at \(MessageStore.defaultDatabasePath)")
            let scheduler = HistoryRetentionScheduler(
                store: store,
                bus: self.changeBus,
                backgroundTasks: self.backgroundTasks
            )
            self.retentionScheduler = scheduler
            scheduler.start()
        } catch {
            // History is an enhancement; the notification service must keep working without it.
            Log.error("Failed to open history database (history disabled): \(error)")
        }
    }

    /// Dock tiles have room for a couple of glyphs, so long counts collapse to "99+".
    /// Zero unreads means no badge at all.
    private static func dockBadgeLabel(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : "\(count)"
    }

    /// Lazily creates (and afterwards reuses) the view model backing the history scene.
    /// Returns nil only during the brief window before the history store has opened.
    public func makeHistoryViewModel() -> HistoryViewModel? {
        if let cachedHistoryViewModel { return cachedHistoryViewModel }
        guard let store = messageStore, let historySync else {
            Log.error("History window opened before the history store was ready")
            return nil
        }
        let vm = HistoryViewModel(store: store, syncService: historySync, configStore: configStore)
        cachedHistoryViewModel = vm
        return vm
    }

    /// Removes history of topics that are no longer subscribed (audit 1.4): without this,
    /// a deleted subscription's unread rows keep the menu bar badge lit with no UI left
    /// that could ever clear them.
    private func pruneOrphanedHistory() {
        guard let store = messageStore, let config = configStore.config else { return }
        let subscribed = config.subscriptions
        Task {
            let tracked = (try? await store.trackedTopics()) ?? []
            let orphans = tracked.subtracting(subscribed)
            guard !orphans.isEmpty else { return }
            for ref in orphans {
                Log.info("Removing history of deleted subscription \(ref.serverURL)/\(ref.topic)")
                try? await store.deleteTopic(serverURL: ref.serverURL, topic: ref.topic)
            }
            self.changeBus.post(topicRef: nil)
        }
    }

    public func serve(configPath: String? = nil) {
        Log.info("Starting ntfyx service...")

        do {
            try configStore.load(from: configPath)
        } catch ConfigError.fileNotFound {
            // The starter always belongs next to the config that was actually requested,
            // never silently at the default path.
            let starterPath = configPath ?? ConfigStore.defaultConfigPath
            do {
                // A first launch owns the empty config it just wrote: the service keeps
                // going and Settings fills it in, instead of making the user edit the
                // file and start a second time.
                try ConfigFile.createInitialConfig(at: starterPath)
                try configStore.load(from: starterPath)
                didCreateInitialConfig = true
                Log.info("未找到配置文件，已在 \(starterPath) 创建初始配置。")
            } catch {
                fatalStartup("未找到配置文件，且创建初始配置失败。", details: "\(error)")
            }
        } catch {
            fatalStartup("加载配置失败。", details: "\(error)")
        }

        guard let config = configStore.config else {
            fatalStartup("配置无效。")
        }

        if config.subscriptions.isEmpty {
            Log.info("尚未配置任何主题：点击菜单栏的 ntfyx 图标 → 设置 添加订阅，保存后即时生效。")
        }

        Log.info("ntfyx v\(AppConstants.effectiveVersion) starting...")
        Log.info("Configured servers: \(config.servers.count)")
        for server in config.servers {
            let topics = server.topics.map { $0.name }.joined(separator: ", ")
            Log.info("  - \(server.url): \(topics)")
        }
        surfaceConfigWarning()

        // Open the history database and wire the history window
        setupHistoryStore()
        pruneOrphanedHistory()

        // Config changes flow through the store (audit E3): internal saves already
        // updated memory and reconcile directly; external edits arrive coalesced via
        // the directory-level watcher, with the store's own writes filtered as echoes.
        configStore.onChange = { [weak self] change in
            guard let self else { return }
            switch change {
            case .internalSave, .externalReload:
                self.reconcileAfterConfigChange()
                self.configSync.noteLocalConfigChanged()
            case .externalFailure:
                // The live config is untouched; message lives in the status UI.
                if let message = self.configStore.loadError {
                    self.connections.showConfigError(message)
                }
            }
        }
        configStore.startWatching()

        Task { @MainActor in
            self.configSync.start()
        }
    }

    /// Reconciles the running service with the store's current config: warning banner,
    /// history pruning/retention and the live-connection diff. Called for internal saves
    /// and accepted external reloads alike.
    private func reconcileAfterConfigChange() {
        guard let config = configStore.config else {
            Log.error("Configuration is invalid")
            return
        }
        Log.info("Reloaded servers: \(config.servers.count)")
        for server in config.servers {
            let topics = server.topics.map { $0.name }.joined(separator: ", ")
            Log.info("  - \(server.url): \(topics)")
        }
        surfaceConfigWarning()
        pruneOrphanedHistory()
        Task { await retentionScheduler?.runIfDue() }

        // Reconcile connections with the new config
        startService()
    }

    private func surfaceConfigWarning() {
        if let warning = configStore.configWarning {
            Log.info("Configuration warning: \(warning)")
            connections.showConfigWarning(warning)
        } else {
            connections.clearConfigIssue()
        }
    }

    public func startService() {
        guard configStore.config != nil else {
            Log.error("配置无效")
            return
        }

        let notificationManager = ensureNotificationManager()

        Task { @MainActor in
            // Check authorization status before starting the service
            let status = await notificationManager.authorizationStatus()

            let statusName: String
            switch status {
            case .notDetermined: statusName = "not determined"
            case .denied: statusName = "denied"
            case .authorized: statusName = "authorized"
            case .provisional: statusName = "provisional"
            case .ephemeral: statusName = "ephemeral"
            @unknown default: statusName = "unknown"
            }
            Log.info("Authorization status: \(statusName)")

            if status == .authorized {
                await self.connectClients()
            } else {
                // Request permission automatically on first launch. The prompt is a
                // SwiftUI scene owned by the app target; a background `serve` denial
                // exits the process inside that hook (process policy is not core's job).
                Log.info("Requesting notification permission...")
                let granted = await AppHooks.requestNotificationPermission?() ?? false
                if granted {
                    Log.success("Permission granted!")
                    await self.connectClients()
                } else {
                    Log.error("Notification permission not granted")
                    Log.info("   Please enable notifications in System Settings → Notifications → ntfyx")
                    if AppMode.isDockApp {
                        // Keep the app running so the user can read history and
                        // retry from System Settings without losing the app.
                        await self.connectClients()
                    }
                }
            }
        }
    }

    private func connectClients() async {
        guard let config = configStore.config else { return }

        // Local notification server only restarts when its port actually changed.
        if localServerPort != config.localServerPort {
            localServerPort = config.localServerPort
            await localServer?.stop()
            localServer = nil
            if let port = config.localServerPort {
                do {
                    // The token gates the loopback API: without it any local process or web
                    // page could forge notifications. Failure keeps the rest of the service up.
                    let server = try LocalNotificationServer(port: port)
                    try await server.start()
                    localServer = server
                } catch {
                    Log.error("Failed to start local notification server on port \(port): \(error)")
                }
            }
        }

        // Update the menu bar server list while keeping untouched servers' state.
        let serverInfos = config.servers.map { server in
            (url: server.url, topics: server.topics.map { $0.name })
        }
        Task { @MainActor in
            connections.updateServers(servers: serverInfos)
        }

        // Diff desired against live clients: only removed/changed connections drop,
        // only new ones connect (audit 2.2).
        let desired = Set(Self.clientSpecs(for: config, authToken: { [configStore] in
            configStore.authToken(forServer: $0)
        }))
        let existing = Set(clientBySpec.keys)

        for spec in existing.subtracting(desired) {
            guard let client = clientBySpec.removeValue(forKey: spec) else { continue }
            eventTaskBySpec.removeValue(forKey: spec)?.cancel()
            connectedSpecs.remove(spec)
            Log.info("Disconnecting client for \(spec.serverURL) (fetch_missed: \(spec.fetchMissed)) — config removed or changed")
            await client.disconnect()
            refreshServerConnectivity(for: spec)
        }

        for spec in desired.subtracting(existing) {
            Log.info("Creating client for \(spec.serverURL) (fetch_missed: \(spec.fetchMissed), topics: \(spec.topics.joined(separator: ", ")))...")
            let client = NtfyClient(
                serverURL: spec.serverURL,
                topics: spec.topics,
                authToken: spec.authToken,
                fetchMissed: spec.fetchMissed
            )
            clientBySpec[spec] = client
            startEventConsumer(for: client, spec: spec)
            await client.connect()
        }
    }

    /// Bridges one client actor's event stream into the main-actor handlers.
    private func startEventConsumer(for client: NtfyClient, spec: ClientSpec) {
        eventTaskBySpec[spec] = Task { [weak self] in
            for await event in client.events {
                guard let self else { return }
                switch event {
                case .connected:
                    self.handleConnected(spec: spec)
                case .disconnected:
                    self.handleDisconnected(spec: spec)
                case .message(let message):
                    self.handleMessage(message, spec: spec)
                case .actionEvent(let event):
                    self.handleActionEvent(event, spec: spec)
                case .catchUpBatch(let batch):
                    self.handleCatchUpBatch(batch, spec: spec)
                case .failure(let error):
                    Log.error("Error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Recomputes and publishes the aggregate connection state of one server.
    private func refreshServerConnectivity(for spec: ClientSpec) {
        let connected = Self.serverConnected(
            serverURL: spec.serverURL,
            allSpecs: Set(clientBySpec.keys),
            connectedSpecs: connectedSpecs
        )
        Task { @MainActor in
            connections.setServerConnected(spec.serverURL, connected: connected)
        }
    }

    /// Manual "reload configuration" menu item (audit E3): re-reads the active file
    /// through the store. A read failure keeps the live config and surfaces an error;
    /// manual reloads are not pushed to cloud sync (nothing changed locally on purpose).
    public func reloadConfig() {
        Log.info("Reloading configuration...")

        do {
            try configStore.reloadFromDisk()
        } catch {
            Log.error("Failed to reload configuration: \(error)")
            let errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            connections.showConfigError(errorMessage)
            return
        }

        reconcileAfterConfigChange()
    }

    private func handleMessage(_ message: NtfyMessage, spec: ClientSpec) {
        Log.info("📩 Received message on topic '\(message.topic)': \(message.message ?? "")")

        let serverURL = spec.serverURL
        let topicConfig = configStore.topicConfig(serverURL: serverURL, topic: message.topic)

        // Persist to the history store (if available)
        if let store = messageStore {
            Task {
                try? await store.upsert(message, serverURL: serverURL)
                self.changeBus.post(topicRef: TopicRef(serverURL: serverURL, topic: message.topic))
            }
        }

        // Handle auto-run scripts
        if let autoRunScript = topicConfig?.autoRunScript, scriptRunner.validateScript(at: autoRunScript) {
            runAutoRunScript(for: message, scriptPath: autoRunScript)
        }

        // Show notification (respects silent flag)
        ensureNotificationManager().showNotification(for: message, topicConfig: topicConfig, serverURL: serverURL)
    }

    /// Replayed history from a `since` catch-up: stored in one transaction per batch and
    /// reported once, so a server replaying tens of thousands of cached messages cannot
    /// occupy the main thread message by message (that is what spun the beachball).
    private func handleCatchUpBatch(_ batch: [NtfyMessage], spec: ClientSpec) {
        let serverURL = spec.serverURL
        guard let store = messageStore else {
            // No history database to batch into, so fall back to the per-message path
            // rather than dropping the replay.
            for message in batch where !message.isActionEvent {
                handleMessage(message, spec: spec)
            }
            return
        }
        Log.info("📩 Catch-up on \(serverURL): \(batch.count) replayed message(s)")

        for message in batch where !message.isActionEvent {
            pendingCatchUp[serverURL, default: CatchUpTally()].add(message)
        }
        scheduleCatchUpBanner()

        // Distinct topic names first: a replay of one busy topic would otherwise build tens of
        // thousands of identical refs and hashes on the way to one notification per topic.
        let topicNames = Set(batch.map(\.topic))
        let topics = Set(topicNames.map { TopicRef(serverURL: serverURL, topic: $0) })
        // The lookup runs once per topic in the batch, not once per message, because each
        // lookup walks the whole server and topic list; the scripts themselves are then
        // validated and spawned off-main — thousands of path checks would otherwise stall
        // the main actor again.
        let runner = scriptRunner
        var scriptByTopic: [String: String] = [:]
        for topic in topicNames {
            if let path = configStore.topicConfig(serverURL: serverURL, topic: topic)?.autoRunScript {
                scriptByTopic[topic] = path
            }
        }
        let scripts = batch.compactMap { message -> (String, NtfyMessage)? in
            guard let path = scriptByTopic[message.topic] else { return nil }
            return (path, message)
        }

        Task.detached(priority: .utility) { [weak self] in
            let revoked = (try? await store.applyBatch(batch, serverURL: serverURL)) ?? []
            for (path, message) in scripts where runner.validateScript(at: path) {
                self?.runAutoRunScript(for: message, scriptPath: path)
            }
            await MainActor.run {
                if !revoked.isEmpty {
                    self?.ensureNotificationManager().revoke(messageIDs: revoked)
                }
                for ref in topics {
                    self?.changeBus.post(topicRef: ref)
                }
            }
        }
    }

    /// Spawns the topic's `auto_run_script` for one message; the caller has to have checked
    /// that the script is there (the batch path checks once per batch, off-main).
    ///
    /// Nonisolated on purpose: it only reads value-type message fields and the stateless,
    /// Sendable script runner, so it can run straight from the background batch task.
    nonisolated private func runAutoRunScript(for message: NtfyMessage, scriptPath path: String) {
        Log.info("Auto-running script: \(path)")
        // Pass message context as environment variables
        var env: [String: String] = [
            "NTFY_ID": message.id,
            "NTFY_TOPIC": message.topic,
            "NTFY_TIME": String(message.time),
            "NTFY_EVENT": message.event,
        ]
        if let title = message.title { env["NTFY_TITLE"] = title }
        if let msg = message.message { env["NTFY_MESSAGE"] = msg }
        if let priority = message.priority { env["NTFY_PRIORITY"] = String(priority) }
        if let tags = message.tags { env["NTFY_TAGS"] = tags.joined(separator: ",") }
        if let click = message.click { env["NTFY_CLICK"] = click }
        scriptRunner.runScript(at: path, withArgument: message.message, extraEnv: env)
    }

    /// Restarts the settle timer: banners are held until the replay stops arriving, then
    /// folded into a single summary.
    private func scheduleCatchUpBanner() {
        catchUpBannerTimer?.invalidate()
        catchUpBannerTimer = Timer.scheduledTimer(
            withTimeInterval: Self.catchUpBannerSettleTime, repeats: false
        ) { [weak self] _ in
            // Timers on the main runloop deliver on the main actor.
            MainActor.assumeIsolated {
                self?.flushCatchUpBanners()
            }
        }
    }

    /// A handful of messages missed while the app was away still gets its own banners;
    /// a whole replayed cache gets one line, because hundreds of sound-bearing banners
    /// freeze notificationcenterd (see NotificationThrottle). Each server gets its own
    /// decision and its own summary, since the banner shows the topics that were replayed.
    private func flushCatchUpBanners() {
        catchUpBannerTimer = nil
        let tallies = pendingCatchUp
        pendingCatchUp.removeAll()

        let manager = ensureNotificationManager()
        for (serverURL, tally) in tallies {
            if tally.count <= Self.catchUpIndividualBannerLimit {
                for message in tally.entries {
                    manager.showNotification(
                        for: message,
                        topicConfig: configStore.topicConfig(
                            serverURL: serverURL, topic: message.topic
                        ),
                        serverURL: serverURL
                    )
                }
                continue
            }
            manager.showCatchUpSummary(count: tally.count, topics: tally.topics.sorted())
        }
    }

    /// Handles server-side "message_delete" (gone) / "message_clear" (marked read)
    /// events by applying them to the matching row in the local history store.
    private func handleActionEvent(_ event: NtfyMessage, spec: ClientSpec) {
        guard let store = messageStore else { return }
        let serverURL = spec.serverURL

        Task {
            _ = try? await store.applyActionEvent(event, serverURL: serverURL)
            // The banner lives in Notification Center, not in the history database:
            // a remote read or delete has to withdraw it explicitly.
            if let messageID = try? await store.targetMessageID(for: event, serverURL: serverURL) {
                ensureNotificationManager().revoke(messageIDs: [messageID])
            }
            self.changeBus.post(topicRef: TopicRef(serverURL: serverURL, topic: event.topic))
        }
    }

    private func handleConnected(spec: ClientSpec) {
        Log.success("Connected to \(spec.serverURL)")
        connectedSpecs.insert(spec)
        refreshServerConnectivity(for: spec)
    }

    private func handleDisconnected(spec: ClientSpec) {
        Log.info("Disconnected from \(spec.serverURL)")
        connectedSpecs.remove(spec)
        refreshServerConnectivity(for: spec)
    }
}
