import Foundation
import Observation

/// In-memory source of truth for the running configuration (audit E3).
///
/// The YAML file is only a persistence backend: every reader in the app observes this
/// object, and every in-app write goes through `save`, which updates memory *and* disk
/// synchronously. External edits (the user hand-editing, an iCloud merge writing the
/// local file) arrive through the directory-level `ConfigWatcher`; their exact raw text
/// is compared against the text this store last knew, so the echo of its own atomic
/// writes never triggers a reload.
///
/// All state is main-actor isolated. Background code (the sync engine, the CLI) uses the
/// nonisolated `ConfigFile` functions directly.
@MainActor
@Observable
public final class ConfigStore {
    public static let shared = ConfigStore()

    /// What the service is running on right now; nil only until the first successful load.
    public private(set) var config: AppConfig?
    /// The file this process loaded and therefore saves/reloads (a `serve --config PATH`
    /// instance must never silently fall back to the default path).
    public private(set) var activePath: String?
    /// Unknown-keys warning from the last successful read (nil when clean).
    public private(set) var configWarning: String?
    /// Localized message when the last external reload failed; nil otherwise. The live
    /// `config` is kept on failure so a broken edit cannot take the service offline.
    private(set) var loadError: String?

    /// Fires after the accepted configuration changed.
    enum Change: Equatable {
        /// An in-app `save`/`replacingTopics` already updated memory.
        case internalSave
        /// An external edit passed validation and was loaded into memory.
        case externalReload
        /// An external edit failed to load; the previous config stays live.
        case externalFailure
    }

    /// Wired by the running coordinator to reconcile connections/history once, after
    /// either kind of accepted change, and to push local edits to cloud sync.
    var onChange: ((Change) -> Void)?

    private var watcher: ConfigWatcher?
    /// Exact text the last load/save produced; the echo filter for watcher events.
    private var knownRaw: String?

    public init() {}

    /// Default configuration path: ~/.config/ntfyx/config.yml
    public static var defaultConfigPath: String { ConfigFile.defaultConfigPath }

    /// The path saves and reloads currently target (explicit path beats the loaded one
    /// beats the default).
    private func resolvePath(_ path: String?) -> String {
        path ?? activePath ?? Self.defaultConfigPath
    }

    // MARK: - Reading

    /// Initial startup load. Missing or invalid files throw; the caller owns the
    /// first-launch starter decision. A successful load pins `activePath`.
    func load(from path: String? = nil) throws {
        let target = resolvePath(path)
        let loaded = try ConfigFile.read(from: target)
        adopt(loaded, path: target)
    }

    /// Re-reads the active file (manual "reload" menu item). Throws on failure but keeps
    /// the live config and records `loadError`.
    @discardableResult
    func reloadFromDisk() throws -> AppConfig {
        let target = resolvePath(nil)
        do {
            let loaded = try ConfigFile.read(from: target)
            adopt(loaded, path: target)
            return loaded.config
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            throw error
        }
    }

    private func adopt(_ loaded: ConfigFile.Loaded, path: String) {
        config = loaded.config
        activePath = path
        configWarning = loaded.warning
        loadError = nil
        knownRaw = loaded.raw
    }

    // MARK: - Writing

    /// Updates memory and atomically persists the config, then fires `.internalSave`.
    /// The watcher's inevitable echo of this write is filtered by `knownRaw`.
    func save(_ config: AppConfig, to path: String? = nil) throws {
        let target = resolvePath(path)
        let raw = try ConfigFile.write(config, to: target)
        self.config = config
        activePath = target
        configWarning = nil
        loadError = nil
        knownRaw = raw
        onChange?(.internalSave)
    }

    /// Rewrites one server's entry while keeping every other setting byte-for-byte.
    /// The write path behind the history window's subscribe/unsubscribe actions.
    func replacingTopics(
        serverURL: String,
        _ transform: (ServerConfig) -> ServerConfig
    ) throws {
        guard let config else { throw ConfigError.fileNotFound }
        guard let index = config.servers.firstIndex(where: { $0.url == serverURL }) else {
            throw ConfigError.decodingError(NSError(
                domain: "ConfigStore",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: LF("配置中没有服务器 %@", serverURL)]
            ))
        }

        var servers = config.servers
        servers[index] = transform(servers[index])
        try save(AppConfig(servers: servers, localServerPort: config.localServerPort))
    }

    // MARK: - Queries

    /// Retrieves the authentication token for a specific server (Keychain first).
    func authToken(forServer serverURL: String) -> String? {
        guard let serverConfig = config?.servers.first(where: { $0.url == serverURL }) else {
            return nil
        }
        if let keychainToken = try? KeychainHelper.getToken(forServer: serverURL) {
            return keychainToken
        }
        return serverConfig.token
    }

    /// Finds a topic configuration for one specific server. The same topic name can
    /// exist on several servers with different settings, so the server is part of the key.
    func topicConfig(serverURL: String, topic topicName: String) -> TopicConfig? {
        config?.topicConfig(serverURL: serverURL, topic: topicName)
    }

    func serverConfig(forURL serverURL: String) -> ServerConfig? {
        config?.server(forURL: serverURL)
    }

    // MARK: - Watching

    /// Installs the directory-level watcher. The handler fires for every accepted
    /// external change; install once during service startup.
    func startWatching() {
        guard watcher == nil else { return }
        let watcher = ConfigWatcher(configPath: activePath ?? Self.defaultConfigPath)
        self.watcher = watcher
        watcher.startWatching { [weak self] in
            self?.handleWatcherEvent()
        }
    }

    func stopWatching() {
        watcher?.stopWatching()
        watcher = nil
    }

    /// Test-only entry point: simulates one settled directory/file event, exercising the
    /// same filtering and external-reload pipeline the real watcher drives.
    func simulateWatcherEventForTesting() {
        handleWatcherEvent()
    }

    private func handleWatcherEvent() {
        let target = resolvePath(nil)

        // Deleted (and not yet recreated): keep serving the last known config until the
        // file comes back — a subsequent create produces another event.
        guard FileManager.default.fileExists(atPath: target) else { return }

        let raw: String
        do {
            raw = try String(contentsOfFile: target, encoding: .utf8)
        } catch {
            return
        }

        // The echo of our own atomic save (and coalesced duplicate events) — bytes the
        // store already has.
        guard raw != knownRaw else { return }

        let loaded: ConfigFile.Loaded
        do {
            loaded = try ConfigFile.read(from: target)
        } catch {
            // Keep the previous config; report and wait for the next event to fix it.
            loadError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            Log.error("Failed to reload externally changed configuration: \(error)")
            onChange?(.externalFailure)
            return
        }

        adopt(loaded, path: target)
        Log.info("Config file changed externally, reloaded...")
        onChange?(.externalReload)
    }
}
