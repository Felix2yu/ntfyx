import Foundation

/// The shape the configuration takes in the cloud: only the fields that mean the same
/// thing on every Mac. Machine-local settings — script and icon paths, notification
/// actions, `local_server_port` — stay out, because a path that only exists on one Mac is
/// a broken subscription on the next one.
public struct SyncDocument: Codable, Equatable, Sendable {
    /// v2: server tokens no longer travel in the cloud file (E2a). A v1 client reading
    /// this version hits its existing `unsupportedVersion` guard and refuses to rewrite it.
    public static let currentVersion = 2
    /// Oldest cloud file version this build still accepts; its tokens are read once for
    /// the one-time Keychain backfill and never written back.
    public static let minimumSupportedVersion = 1

    var version: Int
    public var servers: [SyncServer]

    public init(version: Int = SyncDocument.currentVersion, servers: [SyncServer]) {
        self.version = version
        self.servers = servers
    }

    public static let empty = SyncDocument(servers: [])

    enum CodingKeys: String, CodingKey {
        case version
        case servers
    }

    /// A file from a future client must not be rewritten with today's understanding of it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        servers = try container.decodeIfPresent([SyncServer].self, forKey: .servers) ?? []
    }

    /// Servers by URL, topics by name. Two Macs holding the same configuration then write
    /// byte-identical files, which is what keeps "did the cloud change?" a cheap test.
    var canonicalized: SyncDocument {
        SyncDocument(servers: servers
            .sorted { $0.url < $1.url }
            .map { server in
                var sorted = server
                sorted.topics.sort { $0.name < $1.name }
                return sorted
            }
        )
    }

    var serverIndex: [String: SyncServer] {
        var index: [String: SyncServer] = [:]
        for server in servers { index[server.url] = server }
        return index
    }

    public var topicCount: Int {
        servers.reduce(0) { $0 + $1.topics.count }
    }

    /// A server without topics subscribes to nothing, and the rest of the app already
    /// refuses to save one — so it has no business being in the cloud document either.
    var pruningEmptyServers: SyncDocument {
        SyncDocument(servers: servers.filter { !$0.topics.isEmpty })
    }

    /// The exact document minus any decoded v1 tokens. Used for cloud writes and for the
    /// persisted merge ancestor; the token-carrying copy still feeds the local Keychain
    /// backfill in the same pass.
    var strippingLegacyTokens: SyncDocument {
        SyncDocument(
            version: version,
            servers: servers.map { server in
                var copy = server
                copy.token = nil
                return copy
            }
        )
    }
}

public struct SyncServer: Codable, Equatable, Sendable {
    var url: String
    /// Legacy v1 cloud token. v2 documents never encode it; while a decoded v1 file is
    /// being merged it is kept here transiently so `localWrite` can backfill this Mac's
    /// Keychain once. It is deliberately excluded from `Equatable`, canonical identity
    /// and the three-way merge.
    var token: String?
    var topics: [SyncTopic]
    var allowedSchemes: [String]?
    var allowedDomains: [String]?
    var fetchMissed: Bool?

    init(
        url: String,
        token: String? = nil,
        topics: [SyncTopic],
        allowedSchemes: [String]? = nil,
        allowedDomains: [String]? = nil,
        fetchMissed: Bool? = nil
    ) {
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        // Decode-only: accepted from v1 cloud files for the one-time Keychain backfill.
        token = try container.decodeIfPresent(String.self, forKey: .token)
        topics = try container.decodeIfPresent([SyncTopic].self, forKey: .topics) ?? []
        allowedSchemes = try container.decodeIfPresent([String].self, forKey: .allowedSchemes)
        allowedDomains = try container.decodeIfPresent([String].self, forKey: .allowedDomains)
        fetchMissed = try container.decodeIfPresent(Bool.self, forKey: .fetchMissed)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        // `token` is intentionally never written: credentials live in each Mac's Keychain.
        try container.encode(topics, forKey: .topics)
        try container.encodeIfPresent(allowedSchemes, forKey: .allowedSchemes)
        try container.encodeIfPresent(allowedDomains, forKey: .allowedDomains)
        try container.encodeIfPresent(fetchMissed, forKey: .fetchMissed)
    }

    /// Token is part of neither identity nor convergence: two documents that differ only
    /// in a decoded v1 token are the same cloud configuration.
    public static func == (lhs: SyncServer, rhs: SyncServer) -> Bool {
        lhs.url == rhs.url
            && lhs.topics == rhs.topics
            && lhs.allowedSchemes == rhs.allowedSchemes
            && lhs.allowedDomains == rhs.allowedDomains
            && lhs.fetchMissed == rhs.fetchMissed
    }

    var topicIndex: [String: SyncTopic] {
        var index: [String: SyncTopic] = [:]
        for topic in topics { index[topic.name] = topic }
        return index
    }
}

struct SyncTopic: Codable, Equatable, Sendable {
    var name: String
    var iconSymbol: String?
    var silent: Bool?
    var clickUrl: ClickUrlConfig?
    var fetchMissed: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case iconSymbol = "icon_symbol"
        case silent
        case clickUrl = "click_url"
        case fetchMissed = "fetch_missed"
    }
}

/// Stable textual identity of a value, used to break ties between two Macs that changed
/// the same field differently.
enum SyncFingerprint {
    static func of<T: Encodable>(_ value: T?) -> String {
        guard let value else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "\"\(value)\""
        }
        return text
    }
}
