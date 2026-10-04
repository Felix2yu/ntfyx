import Foundation
import UserNotifications
import AppKit

/// App constants
enum AppConstants {
    static let bundleIdentifier = "com.laurentftech.ntfyx"

    /// Returns the bundle identifier, falling back to hardcoded value if running via symlink
    static var effectiveBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? bundleIdentifier
    }

    /// Returns the app version from Info.plist
    static var effectiveVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

/// Reports a fatal startup problem. A double-clicked app has no terminal to write to,
/// so it reports through an alert instead.
private func fatalStartup(_ message: String, details: String? = nil) -> Never {
    if AppMode.isDockApp {
        // Startup only ever runs on the main queue, from CLI.main().
        MainActor.assumeIsolated {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = details ?? ""
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
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

final class Ntfyx: NtfyClientDelegate, @unchecked Sendable {
    private var clientBySpec: [ClientSpec: NtfyClient] = [:]
    private var clientToServer: [ObjectIdentifier: ClientSpec] = [:]  // which spec drove each client
    private var connectedSpecs: Set<ClientSpec> = []  // audit 2.6: per-connection state
    private var notificationManager: NotificationManager?
    private let scriptRunner = ScriptRunner()
    private var configWatcher: ConfigWatcher?
    private var localServer: LocalNotificationServer?
    private var localServerPort: UInt16?
    private var messageStore: MessageStore?
    private var badgeSync: UnreadBadgeSync?
    private var historySync: HistorySyncService?

    /// Set by serve() when this launch wrote the config file it then loaded: nothing is
    /// subscribed yet, so the UI should go straight to Settings.
    private(set) var didCreateInitialConfig = false

    /// Builds the desired client specs from a config: one per (server, fetch_missed group).
    static func clientSpecs(for config: AppConfig, authToken: (String) -> String?) -> [ClientSpec] {
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
    static func serverConnected(serverURL: String, allSpecs: Set<ClientSpec>, connectedSpecs: Set<ClientSpec>) -> Bool {
        let forServer = allSpecs.filter { $0.serverURL == serverURL }
        return !forServer.isEmpty && forServer.isSubset(of: connectedSpecs)
    }

    init() {
        // Don't initialize notificationManager here - wait until it's needed
    }

    private func ensureNotificationManager() -> NotificationManager {
        if notificationManager == nil {
            notificationManager = NotificationManager.shared
            notificationManager?.setScriptRunner(scriptRunner)
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
                let sync = HistorySyncService(store: store)
                self.historySync = sync
                HistoryWindowController.shared.configure(store: store, syncService: sync)
            }
            // Seed the badges from the database and keep them in sync afterwards.
            Task { @MainActor in
                let badgeSync = UnreadBadgeSync(store: store) { count in
                    StatusBarController.shared.setUnreadCount(count)
                    NSApp.dockTile.badgeLabel = Self.dockBadgeLabel(count)
                }
                badgeSync.start()
                self.badgeSync = badgeSync
            }
            Log.info("History database opened at \(MessageStore.defaultDatabasePath)")
            scheduleHistoryRetention(store: store)
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

    /// Trims expired history once per day (audit 2.4). The delete is bounded by
    /// `RetentionPolicy`; VACUUM only runs when something was actually removed.
    private func scheduleHistoryRetention(store: MessageStore) {
        Task {
            let lastKey = "historyLastRetentionRun"
            let now = Date()
            if let last = UserDefaults.standard.object(forKey: lastKey) as? TimeInterval,
               Calendar.current.isDate(Date(timeIntervalSince1970: last), inSameDayAs: now) {
                return
            }
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastKey)
            do {
                let deleted = try await store.enforceRetention()
                guard deleted > 0 else { return }
                try await store.vacuum()
                Log.info("History retention: removed \(deleted) expired rows")
                NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
            } catch {
                Log.error("History retention failed: \(error)")
            }
        }
    }

    /// Removes history of topics that are no longer subscribed (audit 1.4): without this,
    /// a deleted subscription's unread rows keep the menu bar badge lit with no UI left
    /// that could ever clear them.
    private func pruneOrphanedHistory() {
        guard let store = messageStore, let config = ConfigManager.shared.config else { return }
        let subscribed = config.subscriptions
        Task {
            let tracked = (try? await store.trackedTopics()) ?? []
            let orphans = tracked.subtracting(subscribed)
            guard !orphans.isEmpty else { return }
            for ref in orphans {
                Log.info("Removing history of deleted subscription \(ref.serverURL)/\(ref.topic)")
                try? await store.deleteTopic(serverURL: ref.serverURL, topic: ref.topic)
            }
            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
        }
    }

    func serve(configPath: String? = nil) {
        Log.info("Starting ntfyx service...")

        do {
            try ConfigManager.shared.loadConfig(from: configPath)
        } catch ConfigError.fileNotFound {
            // The starter always belongs next to the config that was actually requested,
            // never silently at the default path.
            let starterPath = configPath ?? ConfigManager.defaultConfigPath
            do {
                // A first launch owns the empty config it just wrote: the service keeps
                // going and Settings fills it in, instead of making the user edit the
                // file and start a second time.
                try ConfigManager.createInitialConfig(at: starterPath)
                try ConfigManager.shared.loadConfig(from: starterPath)
                didCreateInitialConfig = true
                Log.info("未找到配置文件，已在 \(starterPath) 创建初始配置。")
            } catch {
                fatalStartup("未找到配置文件，且创建初始配置失败。", details: "\(error)")
            }
        } catch {
            fatalStartup("加载配置失败。", details: "\(error)")
        }

        guard let config = ConfigManager.shared.config else {
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

        // Open the history database and wire the history window
        setupHistoryStore()
        pruneOrphanedHistory()

        // Start watching config file for changes
        configWatcher = ConfigWatcher(configPath: configPath)
        configWatcher?.startWatching { [weak self] in
            self?.reloadConfig()
            Task { @MainActor in
                ConfigSyncService.shared.noteLocalConfigChanged()
            }
        }

        Task { @MainActor in
            ConfigSyncService.shared.start()
        }
    }

    func startService() {
        guard ConfigManager.shared.config != nil else {
            print("配置无效")
            fflush(stdout)
            return
        }

        let notificationManager = ensureNotificationManager()

        // Check authorization status before starting the service
        notificationManager.getAuthorizationStatus { [weak self] status in
            guard let self = self else { return }

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
                self.connectClients()
            } else {
                // Request permission automatically on first launch
                Log.info("Requesting notification permission...")
                Task { @MainActor in
                    PermissionHelper.requestPermissionsWithWindow { granted in
                        if granted {
                            Log.success("Permission granted!")
                            self.connectClients()
                        } else {
                            Log.error("Notification permission not granted")
                            Log.info("   Please enable notifications in System Settings → Notifications → ntfyx")
                            if AppMode.isDockApp {
                                // Keep the window open so the user can read history and
                                // retry from System Settings without losing the app.
                                self.connectClients()
                            } else {
                                exit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func connectClients() {
        guard let config = ConfigManager.shared.config else { return }

        // Local notification server only restarts when its port actually changed.
        if localServerPort != config.localServerPort {
            localServerPort = config.localServerPort
            localServer?.stop()
            localServer = nil
            if let port = config.localServerPort {
                localServer = LocalNotificationServer(port: port)
                do {
                    try localServer?.start()
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
            StatusBarController.shared.updateServers(servers: serverInfos)
        }

        // Diff desired against live clients: only removed/changed connections drop,
        // only new ones connect (audit 2.2).
        let desired = Set(Self.clientSpecs(for: config, authToken: {
            ConfigManager.shared.getAuthToken(forServer: $0)
        }))
        let existing = Set(clientBySpec.keys)

        for spec in existing.subtracting(desired) {
            guard let client = clientBySpec.removeValue(forKey: spec) else { continue }
            clientToServer.removeValue(forKey: ObjectIdentifier(client))
            connectedSpecs.remove(spec)
            Log.info("Disconnecting client for \(spec.serverURL) (fetch_missed: \(spec.fetchMissed)) — config removed or changed")
            client.disconnect()
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
            client.delegate = self
            clientBySpec[spec] = client
            clientToServer[ObjectIdentifier(client)] = spec
            client.connect()
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
            StatusBarController.shared.setServerConnected(spec.serverURL, connected: connected)
        }
    }

    func reloadConfig() {
        Log.info("Reloading configuration...")

        // Reload config file. On failure the existing connections stay untouched —
        // a broken edit must not take a working service offline.
        do {
            try ConfigManager.shared.loadConfig(from: nil)
            DispatchQueue.main.async {
                // Check for config warnings (unknown keys, etc.)
                if let warning = ConfigManager.shared.configWarning {
                    Log.info("Configuration warning: \(warning)")
                    StatusBarController.shared.showConfigWarning(warning)
                } else {
                    StatusBarController.shared.clearConfigError()
                }
            }
        } catch {
            Log.error("Failed to reload configuration: \(error)")
            let errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            DispatchQueue.main.async {
                StatusBarController.shared.showConfigError(errorMessage)
            }
            return
        }

        guard let config = ConfigManager.shared.config else {
            Log.error("Configuration is invalid")
            return
        }

        Log.info("Reloaded servers: \(config.servers.count)")
        for server in config.servers {
            let topics = server.topics.map { $0.name }.joined(separator: ", ")
            Log.info("  - \(server.url): \(topics)")
        }
        pruneOrphanedHistory()
        if let store = messageStore {
            scheduleHistoryRetention(store: store)  // daily gate inside
        }

        // Reconcile connections with the new config
        startService()
    }

    func ntfyClient(_ client: NtfyClient, didReceiveMessage message: NtfyMessage) {
        Log.info("📩 Received message on topic '\(message.topic)': \(message.message ?? "")")

        let serverURL = clientToServer[ObjectIdentifier(client)]?.serverURL
        let topicConfig = serverURL.flatMap {
            ConfigManager.shared.topicConfig(serverURL: $0, topic: message.topic)
        }

        // Persist to the history store (if available)
        if let store = messageStore, let serverURL {
            Task {
                try? await store.upsert(message, serverURL: serverURL)
                NotificationCenter.default.post(
                    name: .historyStoreDidChange,
                    object: nil,
                    userInfo: ["topicRef": TopicRef(serverURL: serverURL, topic: message.topic)]
                )
            }
        }

        // Handle auto-run scripts
        if let autoRunScript = topicConfig?.autoRunScript {
            if scriptRunner.validateScript(at: autoRunScript) {
                Log.info("Auto-running script: \(autoRunScript)")
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
                scriptRunner.runScript(at: autoRunScript, withArgument: message.message, extraEnv: env)
            }
        }

        // Show notification (respects silent flag)
        ensureNotificationManager().showNotification(for: message, topicConfig: topicConfig, serverURL: serverURL)
    }

    /// Handles server-side "message_delete" (gone) / "message_clear" (marked read)
    /// events by applying them to the matching row in the local history store.
    func ntfyClient(_ client: NtfyClient, didReceiveActionEvent event: NtfyMessage) {
        guard let store = messageStore, let serverURL = clientToServer[ObjectIdentifier(client)]?.serverURL else { return }

        Task {
            _ = try? await store.applyActionEvent(event, serverURL: serverURL)
            // The banner lives in Notification Center, not in the history database:
            // a remote read or delete has to withdraw it explicitly.
            if let messageID = try? await store.targetMessageID(for: event, serverURL: serverURL) {
                ensureNotificationManager().revoke(messageIDs: [messageID])
            }
            NotificationCenter.default.post(
                name: .historyStoreDidChange,
                object: nil,
                userInfo: ["topicRef": TopicRef(serverURL: serverURL, topic: event.topic)]
            )
        }
    }

    func ntfyClient(_ client: NtfyClient, didEncounterError error: Error) {
        Log.error("Error: \(error.localizedDescription)")
    }

    func ntfyClientDidConnect(_ client: NtfyClient) {
        if let spec = clientToServer[ObjectIdentifier(client)] {
            Log.success("Connected to \(spec.serverURL)")
            connectedSpecs.insert(spec)
            refreshServerConnectivity(for: spec)
        } else {
            Log.success("Connected to ntfy server")
        }
    }

    func ntfyClientDidDisconnect(_ client: NtfyClient) {
        if let spec = clientToServer[ObjectIdentifier(client)] {
            Log.info("Disconnected from \(spec.serverURL)")
            connectedSpecs.remove(spec)
            refreshServerConnectivity(for: spec)
        } else {
            Log.info("Disconnected from ntfy server")
        }
    }
}

struct CLI {
    // Keep a strong reference to prevent deallocation
    @MainActor
    static var ntfyAppInstance: Ntfyx?

    @MainActor
    static func main() -> Bool {
        let arguments = CommandLine.arguments

        // When launched without arguments (e.g., via double-click or `open`),
        // start serve mode directly
        if arguments.count < 2 {
            print("🚀 正在启动 ntfyx 服务…")
            ntfyAppInstance = Ntfyx()
            ntfyAppInstance?.serve(configPath: nil)

            guard ConfigManager.shared.config != nil else {
                print("配置无效。请运行 'ntfyx serve' 创建示例配置。")
                return false
            }

            let firstLaunch = ntfyAppInstance?.didCreateInitialConfig ?? false

            // Schedule the actual service start for after RunLoop begins
            // Use Timer to ensure RunLoop is actively running
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [ntfyAppInstance] _ in
                ntfyAppInstance?.startService()
                if AppMode.isDockApp {
                    MainActor.assumeIsolated {
                        if firstLaunch {
                            // Nothing to read yet; the point is to get the first subscription in.
                            SettingsWindowController.shared.showSettings()
                        } else {
                            HistoryWindowController.shared.showHistory()
                        }
                    }
                }
            }

            return true // Needs RunLoop
        }

        let command = arguments[1]

        switch command {
        case "serve":
            let configPath = getFlag(arguments: arguments, flag: "--config")
            ntfyAppInstance = Ntfyx()
            ntfyAppInstance?.serve(configPath: configPath)

            // Extract config for later use
            guard ConfigManager.shared.config != nil else {
                print("配置无效")
                exit(1)
            }

            // Schedule the actual service start for after RunLoop begins
            // Use Timer to ensure RunLoop is actively running
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [ntfyAppInstance] _ in
                ntfyAppInstance?.startService()
            }

            return true // Needs RunLoop

        case "auth":
            handleAuth(arguments: arguments)
            return false

        case "sync":
            handleSync(arguments: arguments)
            return false

        case "test-notify":
            handleTestNotify(arguments: arguments)
            return true // Needs RunLoop

        case "init":
            handleInit(arguments: arguments)
            return false

        case "help", "--help", "-h":
            printUsage()
            exit(0)

        default:
            print("未知命令：\(command)")
            printUsage()
            exit(1)
        }
    }

    static func handleAuth(arguments: [String]) {
        // Check for subcommand: add, list, remove
        guard arguments.count >= 3 else {
            printAuthUsage()
            exit(1)
        }

        let subcommand = arguments[2]

        switch subcommand {
        case "add":
            // ntfyx auth add <server-url> <token>
            guard arguments.count >= 5 else {
                print("用法：ntfyx auth add <server-url> <token>")
                exit(1)
            }
            let server = arguments[3]
            let token = arguments[4]

            do {
                try KeychainHelper.saveToken(token, forServer: server)
                print("✅ 已为服务器保存令牌：\(server)")
            } catch {
                print("❌ 保存令牌失败：\(error)")
                exit(1)
            }

        case "list":
            // ntfyx auth list
            do {
                let servers = try KeychainHelper.listServers()
                if servers.isEmpty {
                    print("钥匙串中未存储任何令牌。")
                } else {
                    print("已为以下服务器存储令牌：")
                    for server in servers {
                        print("  • \(server)")
                    }
                }
            } catch {
                print("❌ 列出服务器失败：\(error)")
                exit(1)
            }

        case "remove":
            // ntfyx auth remove <server-url>
            guard arguments.count >= 4 else {
                print("用法：ntfyx auth remove <server-url>")
                exit(1)
            }
            let server = arguments[3]

            do {
                try KeychainHelper.deleteToken(forServer: server)
                print("✅ 已删除服务器的令牌：\(server)")
            } catch {
                print("❌ 删除令牌失败：\(error)")
                exit(1)
            }

        default:
            print("未知的 auth 子命令：\(subcommand)")
            printAuthUsage()
            exit(1)
        }
    }

    @MainActor
    static func handleSync(arguments: [String]) {
        guard arguments.count >= 3 else {
            printSyncUsage()
            exit(1)
        }
        let subcommand = arguments[2]

        let enabled = UserDefaults.standard.bool(forKey: AppSettings.iCloudSyncEnabledKey)
        let storedDirectory = UserDefaults.standard.string(forKey: AppSettings.iCloudSyncDirectoryKey) ?? ""
        // --dir applies to this run only: a one-off sync from a script or a second account
        // must not quietly repoint the app's own sync folder.
        let cliDirectory = getFlag(arguments: arguments, flag: "--dir")
        let isCustom = !(cliDirectory ?? storedDirectory).isEmpty
        let store = CloudConfigStore(directoryOverride: cliDirectory ?? (storedDirectory.isEmpty ? nil : storedDirectory))

        switch subcommand {
        case "status":
            printSyncStatus(store: store, enabled: enabled, isCustom: isCustom)

        case "pull", "push":
            guard enabled || cliDirectory != nil else {
                print("❌ iCloud 同步未开启。先在 ntfyx 设置 → iCloud 同步 中打开，或用 --dir <PATH> 指定同步文件夹。")
                exit(1)
            }

            do {
                try ConfigManager.shared.loadConfig(from: nil)
            } catch {
                print("❌ 读取本地配置失败：\(error)")
                print("   默认配置位置：\(ConfigManager.defaultConfigPath)，可先运行 'ntfyx init' 创建。")
                exit(1)
            }
            guard let local = ConfigManager.shared.config else {
                print("❌ 未找到默认配置文件：\(ConfigManager.defaultConfigPath)")
                exit(1)
            }

            let preferCloud = subcommand == "pull"
            print(preferCloud ? "🔄 正在拉取云端配置（冲突以云端为准）…" : "🔄 正在推送本机配置（冲突以本机为准）…")

            var state = SyncStateStore.load()
            do {
                let outcome = try ConfigSyncEngine.run(
                    local: local,
                    base: state.base ?? .empty,
                    resolution: preferCloud ? .preferCloud : .preferLocal,
                    store: store
                )
                state.base = outcome.merged
                state.lastCloudFingerprint = outcome.cloudFingerprint
                state.lastSyncedAt = Date()
                SyncStateStore.save(state)

                print("✅ 同步完成：\(outcome.servers) 个服务器、\(outcome.topics) 个主题")
                print(outcome.wroteLocal
                    ? "   本机配置已更新：\(ConfigManager.defaultConfigPath)"
                    : "   本机配置无需改动")
                print(outcome.wroteCloud
                    ? "   云端文件已写入：\(store.cloudFileURL.path)"
                    : "   云端文件无需改动")
                if outcome.conflictCopiesMerged > 0 {
                    print("   已合并并清理 \(outcome.conflictCopiesMerged) 个 iCloud 冲突副本")
                }
                print("   上传与下载由系统在后台完成，其他设备稍后才看得到。")
                if outcome.wroteLocal {
                    print("   ntfyx 正在运行的话会自动热重载这份配置。")
                }
            } catch {
                print("❌ 同步失败：\(error.localizedDescription)")
                if let syncError = error as? ConfigSyncError, case .cloudNotDownloaded = syncError {
                    print("   已向 iCloud 请求下载云端副本，稍后重试即可。")
                }
                exit(1)
            }

        default:
            print("未知的 sync 子命令：\(subcommand)")
            printSyncUsage()
            exit(1)
        }
    }

    static func printSyncStatus(store: CloudConfigStore, enabled: Bool, isCustom: Bool) {
        print("iCloud 同步：\(enabled ? "已开启" : "未开启")")
        print("同步文件夹：\(store.rootDirectory)\(isCustom ? "（自定义）" : "")")

        let cloudPath = store.cloudFileURL.path
        if FileManager.default.fileExists(atPath: cloudPath) {
            let size = ((try? FileManager.default.attributesOfItem(atPath: cloudPath))?[.size] as? Int) ?? 0
            print("云端文件：已存在（\(size) 字节）")
        } else {
            print("云端文件：尚不存在（首次同步时创建）")
        }

        let state = SyncStateStore.load()
        if let base = state.base {
            print("本机基线：\(base.servers.count) 个服务器、\(base.topicCount) 个主题")
        } else {
            print("本机基线：尚无（这台机器还没完成过同步）")
        }
        if let date = state.lastSyncedAt {
            print("上次同步：\(SyncTimeFormat.string(date))")
        } else {
            print("上次同步：从未")
        }

        let conflicts = store.conflictCopies().count
        if conflicts > 0 {
            print("冲突副本：\(conflicts) 个，下次同步会合并进来")
        }
        if !enabled {
            print("")
            print("未开启时 pull/push 需要 --dir <PATH> 指定同步文件夹；持续同步由设置中的开关控制。")
        }
    }

    static func printSyncUsage() {
        print("""
        用法：ntfyx sync <子命令> [--dir <PATH>]

        子命令：
            status          显示同步状态（只读）
            pull            取云端配置合并到本机，冲突以云端为准
            push            把本机配置合入云端，冲突以本机为准

        pull 与 push 都会把合并结果同时写回本机文件和云端文件，区别只在冲突时以哪边
        为准；服务器与主题的新增取并集，任一边删除都生效。

        --dir 只作用于本次运行，不会改动设置里的同步文件夹。

        示例：
            ntfyx sync status
            ntfyx sync pull
            ntfyx sync push --dir /Volumes/nas/ntfyx

        注意：命令行只做一次合并。配置改动自动上云、定时拉取这些持续同步，
        仍由运行中的 ntfyx 服务负责。
        """)
    }

    static func printAuthUsage() {
        print("""
        用法：ntfyx auth <子命令>

        子命令：
            add <server-url> <token>    将令牌存入钥匙串
            list                        列出所有已存令牌的服务器
            remove <server-url>         从钥匙串删除令牌

        示例：
            ntfyx auth add https://ntfy.sh tk_mytoken
            ntfyx auth list
            ntfyx auth remove https://ntfy.sh
        """)
    }

    @MainActor
    static func handleTestNotify(arguments: [String]) {
        guard let topic = getFlag(arguments: arguments, flag: "--topic") else {
            print("用法：ntfyx test-notify --topic <NAME>")
            exit(1)
        }

        print("🚀 正在通过 GUI 窗口请求通知权限…")

        PermissionHelper.requestPermissionsWithWindow { granted in
            Task { @MainActor in
                if granted {
                    let notificationManager = NotificationManager.shared
                    notificationManager.showTestNotification(topic: topic)
                    print("✅ 已发送主题 \(topic) 的测试通知")
                    // Give time for notification to be delivered, then exit cleanly
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        NSApp.terminate(nil)
                    }
                } else {
                    print("❌ 通知权限被拒绝")
                    print("")
                    print("💡 应用现在应已出现在 系统设置 → 通知 中")
                    print("   请在其中开启通知后重试。")
                    NSApp.terminate(nil)
                }
            }
        }

        // Don't call RunLoop here - it's managed by the entry point
    }

    static func handleInit(arguments: [String]) {
        let configPath = getFlag(arguments: arguments, flag: "--path") ?? ConfigManager.defaultConfigPath

        do {
            if try ConfigManager.createSampleConfig(at: configPath) {
                print("示例配置已创建于：\(configPath)")
                print("请编辑配置文件，然后运行 'ntfyx serve' 启动服务。")
            } else {
                print("配置文件已存在，未做修改：\(configPath)")
            }
        } catch {
            print("创建配置失败：\(error)")
            exit(1)
        }
    }

    static func getFlag(arguments: [String], flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    static func printUsage() {
        print("""
        ntfyx - 原生 macOS 通知与自动化工具

        用法：
            ntfyx <命令> [选项]

        命令：
            serve                    启动通知服务
                --config <PATH>      可选：自定义配置文件路径

            auth <子命令>            管理钥匙串中的认证令牌
                add <url> <token>    为服务器存储令牌
                list                 列出所有已存令牌的服务器
                remove <url>         删除某服务器的令牌

            sync <子命令>            iCloud 配置同步（--dir <PATH> 可临时指定同步文件夹）
                status               显示同步状态（只读）
                pull                 取云端配置合并到本机，冲突以云端为准
                push                 把本机配置合入云端，冲突以本机为准

            test-notify              发送测试通知
                --topic <NAME>       要测试的主题名称

            init                     创建示例配置文件
                --path <PATH>        可选：自定义配置文件路径

            help                     显示本帮助信息

        示例：
            # 创建配置
            ntfyx init

            # 将认证令牌存入钥匙串
            ntfyx auth add https://ntfy.sh tk_mytoken

            # 列出已存储的令牌
            ntfyx auth list

            # 删除令牌
            ntfyx auth remove https://ntfy.sh

            # 新机器上先把云端的配置拉下来
            ntfyx sync pull

            # 启动服务
            ntfyx serve

            # 测试通知
            ntfyx test-notify --topic alerts

        配置：
            默认配置位置：~/.config/ntfyx/config.yml

            令牌可存放于：
            - 配置文件中（各服务器下的 token: 字段）
            - 钥匙串中（使用 'auth add' 命令）——更安全

        更多信息请访问：https://github.com/Felix2yu/ntfyx
        """)
    }
}

// App delegate to disable state restoration (prevents crashes from corrupted saved state)
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldRestoreSecureUntitleableWindows(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return false
    }

    /// Clicking the Dock icon with no visible window brings the history window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if AppMode.isDockApp && !flag {
            HistoryWindowController.shared.showHistory()
        }
        return true
    }
}

// Entry point - Initialize NSApplication for proper macOS app behavior
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate

// Schedule CLI execution after the run loop starts to ensure AppKit is fully initialized
// This fixes the frozen window issue where events weren't being processed
DispatchQueue.main.async {
    // Regular app (Dock icon + windows) when launched by double-click or `open`,
    // menu-bar-only background service when launched with a CLI subcommand.
    AppMode.configure()

    let needsRunLoop = CLI.main()
    if !needsRunLoop {
        // Commands that don't need the run loop can exit immediately
        NSApp.terminate(nil)
    } else {
        StatusBarController.shared.setup()
        StatusBarController.shared.onReloadConfig = {
            CLI.ntfyAppInstance?.reloadConfig()
        }

        // Show any initial config warnings
        if let warning = ConfigManager.shared.configWarning {
            Log.info("Configuration warning: \(warning)")
            StatusBarController.shared.showConfigWarning(warning)
        }
    }
}

// Start the run loop - this properly initializes AppKit and processes events
app.run()
