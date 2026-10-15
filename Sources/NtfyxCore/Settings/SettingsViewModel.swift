import Foundation
import Observation

struct EditableServer: Identifiable {
    let id: UUID
    var url: String
    var token: String
    var storeInKeychain: Bool
    var fetchMissed: Bool
    var topics: [EditableTopic]

    // Server-level click-URL security options (audit 3.3): mode + raw input are the
    // editing state, the YAML value is derived from them on save.
    var schemesMode: URLRestriction
    var schemesInput: String
    var domainsMode: URLRestriction
    var domainsInput: String

    var allowedSchemes: [String]? {
        switch schemesMode {
        case .off: return nil
        case .denyAll: return []
        case .custom: return parseRestrictionList(schemesInput)
        }
    }

    var allowedDomains: [String]? {
        switch domainsMode {
        case .off: return nil
        case .denyAll: return []
        case .custom: return parseRestrictionList(domainsInput)
        }
    }

    // Track original URL for Keychain cleanup on rename
    var originalUrl: String?

    init(id: UUID = UUID(), url: String = "", token: String = "", storeInKeychain: Bool = false, fetchMissed: Bool = false, topics: [EditableTopic] = [], allowedSchemes: [String]? = nil, allowedDomains: [String]? = nil, originalUrl: String? = nil) {
        self.id = id
        self.url = url
        self.token = token
        self.storeInKeychain = storeInKeychain
        self.fetchMissed = fetchMissed
        self.topics = topics
        self.schemesMode = URLRestriction(deriving: allowedSchemes)
        self.schemesInput = (allowedSchemes ?? []).joined(separator: ", ")
        self.domainsMode = URLRestriction(deriving: allowedDomains)
        self.domainsInput = (allowedDomains ?? []).joined(separator: ", ")
        self.originalUrl = originalUrl
    }
}

struct EditableTopic: Identifiable {
    let id: UUID
    var name: String
    var displayName: String?
    var fetchMissed: Bool?

    /// What the row and every other surface show: the note when it holds text, the id otherwise.
    var label: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? name : trimmed
    }

    // Phase 2 fields (preserved during round-trip but not editable yet)
    var iconPath: String?
    var iconSymbol: String?
    var autoRunScript: String?
    var autoRunScriptArgs: [String]?
    var silent: Bool?
    var clickUrl: ClickUrlConfig?
    var actions: [NotificationAction]?

    init(id: UUID = UUID(), name: String = "", displayName: String? = nil, fetchMissed: Bool? = nil, iconPath: String? = nil, iconSymbol: String? = nil, autoRunScript: String? = nil, autoRunScriptArgs: [String]? = nil, silent: Bool? = nil, clickUrl: ClickUrlConfig? = nil, actions: [NotificationAction]? = nil) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.fetchMissed = fetchMissed
        self.iconPath = iconPath
        self.iconSymbol = iconSymbol
        self.autoRunScript = autoRunScript
        self.autoRunScriptArgs = autoRunScriptArgs
        self.silent = silent
        self.clickUrl = clickUrl
        self.actions = actions
    }
}

@MainActor
@Observable
final class SettingsViewModel {
    /// Live connection rows are read directly from the injected registry (audit B2); there
    /// is no 3-second copied snapshot anymore.
    let connections: ConnectionRegistry
    /// In-memory configuration source of truth (audit E3); saves go through it.
    let configStore: ConfigStore

    var servers: [EditableServer] = [] {
        didSet { hasUnsavedChanges = true }
    }
    var localServerPort: String = "" {
        didSet { hasUnsavedChanges = true }
    }
    var hasUnsavedChanges: Bool = false
    var saveError: String?

    // MARK: - Connectivity tests (against the edited, possibly unsaved values)

    enum ServerTestState: Equatable {
        case testing
        case reachable(version: String?)
        case tokenRejected
        case failed(reason: String)
    }

    enum TopicTestState: Equatable {
        case sending
        case success
        case failed(reason: String)
    }

    var serverTestStates: [UUID: ServerTestState] = [:]
    var topicTestStates: [UUID: TopicTestState] = [:]

    /// Test seam: session used by the connectivity probes.
    var probeSession: URLSession = .shared

    func testConnection(for server: EditableServer) {
        guard serverTestStates[server.id] != .testing else { return }
        serverTestStates[server.id] = .testing
        let url = server.url
        let token = server.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let topic = server.topics.first?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { [weak self] in
            guard let self else { return }
            let outcome = await ConnectivityTest.testConnection(
                serverURL: url,
                token: token.isEmpty ? nil : token,
                topic: topic?.isEmpty == false ? topic : nil,
                session: self.probeSession
            )
            switch outcome {
            case .serverReachable(let version):
                self.serverTestStates[server.id] = .reachable(version: version)
            case .tokenRejected:
                self.serverTestStates[server.id] = .tokenRejected
            case .unreachable(let reason):
                self.serverTestStates[server.id] = .failed(reason: reason)
            default:
                self.serverTestStates[server.id] = .failed(reason: "意外的探测结果")
            }
        }
    }

    func sendTestNotification(in server: EditableServer, topic: EditableTopic) {
        guard topicTestStates[topic.id] != .sending else { return }
        topicTestStates[topic.id] = .sending
        let url = server.url
        let name = topic.name
        let token = server.token.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { [weak self] in
            guard let self else { return }
            let outcome = await ConnectivityTest.sendTestNotification(
                serverURL: url,
                topic: name,
                token: token.isEmpty ? nil : token,
                session: self.probeSession
            )
            switch outcome {
            case .published:
                self.topicTestStates[topic.id] = .success
            case .writeRejected(let status):
                let hint = (status == 401 || status == 403) ? "（无写入权限或令牌错误）" : ""
                self.topicTestStates[topic.id] = .failed(reason: "HTTP \(status)\(hint)")
            case .unreachable(let reason):
                self.topicTestStates[topic.id] = .failed(reason: reason)
            default:
                self.topicTestStates[topic.id] = .failed(reason: "意外的发送结果")
            }
        }
    }

    init(connections: ConnectionRegistry = .shared, configStore: ConfigStore = .shared) {
        self.connections = connections
        self.configStore = configStore
    }

    func loadFromConfig() {
        let config = configStore.config

        if let port = config?.localServerPort {
            localServerPort = String(port)
        } else {
            localServerPort = ""
        }

        servers = (config?.servers ?? []).map { server in
            // Check if token is stored in Keychain
            let keychainToken = try? KeychainHelper.getToken(forServer: server.url)
            let hasKeychainToken = keychainToken != nil
            let tokenValue = keychainToken ?? server.token ?? ""

            return EditableServer(
                url: server.url,
                token: tokenValue,
                storeInKeychain: hasKeychainToken,
                fetchMissed: server.fetchMissed ?? false,
                topics: server.topics.map { topic in
                    EditableTopic(
                        name: topic.name,
                        displayName: topic.displayName,
                        fetchMissed: topic.fetchMissed,
                        iconPath: topic.iconPath,
                        iconSymbol: topic.iconSymbol,
                        autoRunScript: topic.autoRunScript,
                        autoRunScriptArgs: topic.autoRunScriptArgs,
                        silent: topic.silent,
                        clickUrl: topic.clickUrl,
                        actions: topic.actions
                    )
                },
                allowedSchemes: server.allowedSchemes,
                allowedDomains: server.allowedDomains,
                originalUrl: server.url
            )
        }

        hasUnsavedChanges = false
        saveError = nil
    }

    func save(to path: String? = nil) {
        saveError = nil

        // Validation
        for server in servers {
            if server.url.trimmingCharacters(in: .whitespaces).isEmpty {
                saveError = "服务器地址不能为空"
                return
            }
            for topic in server.topics {
                if topic.name.trimmingCharacters(in: .whitespaces).isEmpty {
                    saveError = "主题名称不能为空"
                    return
                }
                // Menu bar rows and notification titles have to stay readable.
                let note = topic.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if note.count > 64 {
                    saveError = "主题 \(topic.name) 的备注最长 64 个字符"
                    return
                }
            }
            // Check for duplicate topic names within a server
            let topicNames = server.topics.map { $0.name }
            if Set(topicNames).count != topicNames.count {
                saveError = "服务器 \(server.url) 中存在重复的主题名称"
                return
            }
        }

        // Parse port
        let port: UInt16?
        if localServerPort.trimmingCharacters(in: .whitespaces).isEmpty {
            port = nil
        } else if let p = UInt16(localServerPort) {
            port = p
        } else {
            saveError = "端口号无效"
            return
        }

        // Build AppConfig
        let serverConfigs = servers.map { server in
            let topicConfigs = server.topics.map { topic in
                let note = topic.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return TopicConfig(
                    name: topic.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    displayName: note.isEmpty ? nil : note,
                    iconPath: topic.iconPath,
                    iconSymbol: topic.iconSymbol,
                    autoRunScript: topic.autoRunScript,
                    autoRunScriptArgs: topic.autoRunScriptArgs,
                    silent: topic.silent,
                    clickUrl: topic.clickUrl,
                    actions: topic.actions,
                    fetchMissed: topic.fetchMissed
                )
            }

            // If storing in Keychain, don't write token to YAML
            let yamlToken: String? = server.storeInKeychain ? nil : (server.token.isEmpty ? nil : server.token)

            return ServerConfig(
                url: server.url.trimmingCharacters(in: .whitespacesAndNewlines),
                token: yamlToken,
                topics: topicConfigs,
                allowedSchemes: server.allowedSchemes,
                allowedDomains: server.allowedDomains,
                fetchMissed: server.fetchMissed ? true : nil
            )
        }

        let appConfig = AppConfig(servers: serverConfigs, localServerPort: port)

        // Reject invalid configs before touching the Keychain or the config file.
        do {
            try ConfigValidator.validate(appConfig)
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return
        }

        // Handle Keychain operations
        for server in servers {
            let token = server.token.trimmingCharacters(in: .whitespaces)

            if server.storeInKeychain && !token.isEmpty {
                try? KeychainHelper.saveToken(token, forServer: server.url)

                // If URL changed, clean up old Keychain entry
                if let oldUrl = server.originalUrl, oldUrl != server.url {
                    try? KeychainHelper.deleteToken(forServer: oldUrl)
                }
            } else if !server.storeInKeychain {
                // Remove from Keychain if user unchecked the option
                if let oldUrl = server.originalUrl {
                    try? KeychainHelper.deleteToken(forServer: oldUrl)
                }
                try? KeychainHelper.deleteToken(forServer: server.url)
            }
        }

        // Write through the store: memory updates immediately, the file is rewritten
        // atomically, and the store's change callback reconciles the running service.
        do {
            try configStore.save(appConfig, to: path)
            hasUnsavedChanges = false

            // Update originalUrl for all servers after successful save
            for i in servers.indices {
                servers[i].originalUrl = servers[i].url
            }
            // Reset unsaved flag (the assignment above triggers didSet)
            hasUnsavedChanges = false
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
        }
    }

    func cancel() {
        loadFromConfig()
    }

    // MARK: - Server CRUD

    func addServer() {
        let server = EditableServer(
            url: "https://",
            topics: [EditableTopic(name: "")]
        )
        servers.append(server)
    }

    func removeServer(_ server: EditableServer) {
        servers.removeAll { $0.id == server.id }
    }

    // MARK: - Topic CRUD

    func addTopic(to serverID: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        servers[index].topics.append(EditableTopic(name: ""))
    }

    func removeTopic(_ topicID: UUID, from serverID: UUID) {
        guard let serverIndex = servers.firstIndex(where: { $0.id == serverID }) else { return }
        servers[serverIndex].topics.removeAll { $0.id == topicID }
    }

    // MARK: - Binding helpers

    func serverBinding(for id: UUID) -> EditableServer? {
        servers.first { $0.id == id }
    }
}
