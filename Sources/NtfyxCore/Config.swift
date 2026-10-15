import Foundation

public struct NotificationAction: Codable, Equatable, Sendable {
    var title: String
    var type: String      // "script", "view", "shortcut", or "applescript"
    var path: String?     // for scripts and applescript files
    var url: String?      // for view actions
    var name: String?     // for shortcuts (the shortcut name)
    var script: String?   // for inline applescript
    /// Structured argv for `script` actions; bypasses the shell entirely.
    var args: [String]?

    init(title: String, type: String, path: String? = nil, url: String? = nil, name: String? = nil, script: String? = nil, args: [String]? = nil) {
        self.title = title
        self.type = type
        self.path = path
        self.url = url
        self.name = name
        self.script = script
        self.args = args
    }
}

public struct TopicConfig: Codable, Equatable, Sendable {
    let name: String
    let iconPath: String?
    let iconSymbol: String?
    let autoRunScript: String?
    /// Structured argv for `autoRunScript`; when present the script bypasses the shell.
    let autoRunScriptArgs: [String]?
    let silent: Bool?
    let clickUrl: ClickUrlConfig?  // Control click behavior: true/false/custom URL
    let actions: [NotificationAction]?
    let fetchMissed: Bool?

    init(name: String, iconPath: String? = nil, iconSymbol: String? = nil, autoRunScript: String? = nil, autoRunScriptArgs: [String]? = nil, silent: Bool? = nil, clickUrl: ClickUrlConfig? = nil, actions: [NotificationAction]? = nil, fetchMissed: Bool? = nil) {
        self.name = name
        self.iconPath = iconPath
        self.iconSymbol = iconSymbol
        self.autoRunScript = autoRunScript
        self.autoRunScriptArgs = autoRunScriptArgs
        self.silent = silent
        self.clickUrl = clickUrl
        self.actions = actions
        self.fetchMissed = fetchMissed
    }

    enum CodingKeys: String, CodingKey {
        case name
        case iconPath = "icon_path"
        case iconSymbol = "icon_symbol"
        case autoRunScript = "auto_run_script"
        case autoRunScriptArgs = "auto_run_script_args"
        case silent
        case clickUrl = "click_url"
        case actions
        case fetchMissed = "fetch_missed"
    }

    /// Whether to fetch missed messages for this topic (default: false)
    var shouldFetchMissed: Bool {
        fetchMissed ?? false
    }
}

/// Represents click_url config: can be a URL string, true (use default), or false (disabled)
public enum ClickUrlConfig: Codable, Equatable, Sendable {
    case enabled          // true or not specified: use webUrl or url
    case disabled         // false: don't open anything on click
    case custom(String)   // custom URL

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolValue = try? container.decode(Bool.self) {
            self = boolValue ? .enabled : .disabled
        } else if let stringValue = try? container.decode(String.self) {
            self = .custom(stringValue)
        } else {
            self = .enabled
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .enabled:
            try container.encode(true)
        case .disabled:
            try container.encode(false)
        case .custom(let url):
            try container.encode(url)
        }
    }
}

public struct ServerConfig: Codable, Equatable, Sendable {
    let url: String
    let token: String?
    let topics: [TopicConfig]
    let allowedSchemes: [String]?
    let allowedDomains: [String]?
    let fetchMissed: Bool?

    init(url: String, token: String? = nil, topics: [TopicConfig], allowedSchemes: [String]? = nil, allowedDomains: [String]? = nil, fetchMissed: Bool? = nil) {
        self.url = url
        self.token = token
        self.topics = topics
        self.allowedSchemes = allowedSchemes
        self.allowedDomains = allowedDomains
        self.fetchMissed = fetchMissed
    }

    enum CodingKeys: String, CodingKey {
        case url
        case token
        case topics
        case allowedSchemes = "allowed_schemes"
        case allowedDomains = "allowed_domains"
        case fetchMissed = "fetch_missed"
    }

    /// Whether to fetch missed messages on reconnect (default: false)
    var shouldFetchMissed: Bool {
        fetchMissed ?? false
    }

    /// Returns the list of allowed URL schemes, defaulting to ["http", "https"]
    var effectiveAllowedSchemes: [String] {
        allowedSchemes ?? ["http", "https"]
    }

    /// Validates if a URL's scheme is allowed for this server
    func isSchemeAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return effectiveAllowedSchemes.map { $0.lowercased() }.contains(scheme)
    }

    /// Validates if a domain is allowed for this server (nil means all domains allowed, empty array means none allowed)
    func isDomainAllowed(_ url: URL) -> Bool {
        guard let allowedDomains else {
            return true  // No restriction if not configured (nil)
        }
        guard !allowedDomains.isEmpty else {
            return false  // Empty array means no domains allowed
        }
        guard let host = url.host?.lowercased() else { return false }
        return allowedDomains.map { $0.lowercased() }.contains { allowedDomain in
            // Support wildcard subdomains: "*.example.com" matches "sub.example.com"
            if allowedDomain.hasPrefix("*.") {
                let baseDomain = String(allowedDomain.dropFirst(2))
                return host == baseDomain || host.hasSuffix("." + baseDomain)
            }
            return host == allowedDomain
        }
    }

    /// Validates if a URL is allowed (both scheme and domain)
    func isUrlAllowed(_ url: URL) -> Bool {
        return isSchemeAllowed(url) && isDomainAllowed(url)
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public let servers: [ServerConfig]
    public let localServerPort: UInt16?

    public init(servers: [ServerConfig], localServerPort: UInt16? = nil) {
        self.servers = servers
        self.localServerPort = localServerPort
    }

    enum CodingKeys: String, CodingKey {
        case servers
        case localServerPort = "local_server_port"
    }

    // Convenience: all topics across all servers
    var allTopics: [TopicConfig] {
        servers.flatMap { $0.topics }
    }

    /// Finds the server config by its base URL. Topic behaviour must be resolved per
    /// (server, topic) — the same topic name on different servers has different config.
    func server(forURL url: String) -> ServerConfig? {
        servers.first { $0.url == url }
    }

    /// Finds a topic's configuration within one specific server.
    func topicConfig(serverURL: String, topic topicName: String) -> TopicConfig? {
        server(forURL: serverURL)?.topics.first { $0.name == topicName }
    }

    /// Every currently subscribed (server, topic) pair; anything in the history
    /// database outside this set is an orphan left by a deleted subscription.
    var subscriptions: Set<TopicRef> {
        Set(servers.flatMap { server in
            server.topics.map { TopicRef(serverURL: server.url, topic: $0.name) }
        })
    }
}

public enum ConfigError: Error, LocalizedError {
    case fileNotFound
    case invalidYAML(Error)
    case decodingError(Error)
    case insecureFilePermissions(String)
    case unknownKeys(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "未找到配置文件"
        case .invalidYAML(let error):
            return "YAML 无效：\(error.localizedDescription)"
        case .decodingError(let error):
            return "配置错误：\(error.localizedDescription)"
        case .insecureFilePermissions(let message):
            return message
        case .unknownKeys(let details):
            return "未知配置项：\n\(details)"
        }
    }
}

/// Validates configuration before use
struct ConfigValidator {

    /// Validates the entire config
    static func validate(_ config: AppConfig) throws {
        // Validate servers
        for server in config.servers {
            try validateServerURL(server.url)

            // Validate topics
            guard !server.topics.isEmpty else {
                throw ConfigError.decodingError(NSError(
                    domain: "ConfigValidator",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "服务器 \(server.url) 未配置任何主题"]
                ))
            }

            // Validate unique topic names per server
            let topicNames = server.topics.map { $0.name }
            if topicNames.count != Set(topicNames).count {
                throw ConfigError.decodingError(NSError(
                    domain: "ConfigValidator",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "服务器 \(server.url) 中存在重复的主题名称"]
                ))
            }
        }
    }

    /// Validates a server URL
    static func validateServerURL(_ urlString: String) throws {
        guard let url = URL(string: urlString) else {
            throw ConfigError.decodingError(NSError(
                domain: "ConfigValidator",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "URL 格式无效：\(urlString)"]
            ))
        }

        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ConfigError.decodingError(NSError(
                domain: "ConfigValidator",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "URL 必须使用 http 或 https 协议：\(urlString)"]
            ))
        }

        guard url.host != nil && !url.host!.isEmpty else {
            throw ConfigError.decodingError(NSError(
                domain: "ConfigValidator",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "URL 必须包含有效主机名：\(urlString)"]
            ))
        }
    }
}
