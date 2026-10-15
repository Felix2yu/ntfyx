import Foundation

/// Reads one server's Keychain token, distinguishing "no token stored" from "could not
/// tell". Publishing a nil token because the Keychain was unreachable would delete the
/// token on every other Mac, so a failed read has to stop the sync rather than be
/// mistaken for an absent value.
public enum KeychainTokenReader {
    public enum Outcome: Equatable {
        case value(String)
        case absent
        case failed
    }

    public static func read(_ serverURL: String) -> Outcome {
        do {
            return .value(try KeychainHelper.getToken(forServer: serverURL))
        } catch KeychainError.itemNotFound {
            return .absent
        } catch {
            return .failed
        }
    }
}

/// Converts between the on-disk `AppConfig` and the cloud `SyncDocument`, and writes a
/// merged document back the way this particular Mac keeps its configuration.
public enum ConfigSyncTranslator {
    /// A Keychain side effect a local write needs. Tokens never travel in the cloud file
    /// (E2a), so the only possible actions are "leave the Keychain alone" and
    /// "store this once (migration from inline YAML, or the one-time v1 cloud backfill)".
    public enum TokenPlacement: Equatable {
        case unchanged
        case keychain(String)
    }

    struct LocalWrite {
        var config: AppConfig
        var tokenPlacements: [String: TokenPlacement] = [:]
    }

    /// Builds the cloud document from the local file. It never carries a token, whether the
    /// credential on this Mac lives in the Keychain or inline in the YAML: the cloud copy
    /// is shared state and tokens stay per-Machine.
    static func document(from config: AppConfig) -> SyncDocument {
        SyncDocument(servers: config.servers.map { server in
            SyncServer(
                url: server.url,
                topics: server.topics.map { topic in
                    SyncTopic(
                        name: topic.name,
                        iconSymbol: topic.iconSymbol,
                        silent: topic.silent,
                        clickUrl: topic.clickUrl,
                        fetchMissed: topic.fetchMissed
                    )
                },
                allowedSchemes: server.allowedSchemes,
                allowedDomains: server.allowedDomains,
                fetchMissed: server.fetchMissed
            )
        }).pruningEmptyServers.canonicalized
    }

    static func localWrite(
        from merged: SyncDocument,
        preserving local: AppConfig,
        keychainToken: (String) -> KeychainTokenReader.Outcome
    ) -> LocalWrite {
        let mergedIndex = merged.serverIndex
        var servers: [ServerConfig] = []
        var placements: [String: TokenPlacement] = [:]
        var writtenURLs: Set<String> = []

        // This Mac's own order first: the history sidebar and a hand-written file both read
        // better when a sync does not shuffle the entries the user already had.
        for server in local.servers {
            guard let sync = mergedIndex[server.url] else { continue }
            let mergedServer = merge(server: sync, into: server, keychainToken: keychainToken(server.url))
            servers.append(mergedServer.config)
            if mergedServer.tokenPlacement != .unchanged {
                placements[server.url] = mergedServer.tokenPlacement
            }
            writtenURLs.insert(server.url)
        }
        for sync in merged.servers where !writtenURLs.contains(sync.url) {
            let mergedServer = merge(server: sync, into: nil, keychainToken: keychainToken(sync.url))
            servers.append(mergedServer.config)
            if mergedServer.tokenPlacement != .unchanged {
                placements[sync.url] = mergedServer.tokenPlacement
            }
        }

        return LocalWrite(
            config: AppConfig(servers: servers, localServerPort: local.localServerPort),
            tokenPlacements: placements
        )
    }

    private struct MergedServer {
        var config: ServerConfig
        var tokenPlacement: TokenPlacement
    }

    private static func merge(
        server sync: SyncServer,
        into existing: ServerConfig?,
        keychainToken: KeychainTokenReader.Outcome
    ) -> MergedServer {
        var remaining = sync.topicIndex
        var topics: [TopicConfig] = []
        var writtenNames: Set<String> = []

        for topic in existing?.topics ?? [] {
            guard let synced = remaining.removeValue(forKey: topic.name) else { continue }
            topics.append(merge(topic: synced, into: topic))
            writtenNames.insert(topic.name)
        }
        for synced in sync.topics where !writtenNames.contains(synced.name) {
            topics.append(merge(topic: synced, into: nil))
        }

        // E2a token policy. Servers touched by a sync never keep a token in the YAML, and
        // a token is only ever *added* to the Keychain, never removed or overwritten:
        //
        //   Keychain has one   → leave it alone (a v1 cloud token must not clobber it)
        //   inline YAML token  → migrate it into the Keychain, clear the YAML field
        //   v1 cloud token only → one-time Keychain backfill
        //   nothing anywhere   → nothing to do (a new Mac types the token in once itself)
        //
        // `.failed` must never reach this point (the engine preflights and aborts the
        // whole pass); leave the server untouched if it ever does.
        let yamlToken: String?
        let placement: TokenPlacement
        let existingToken = existing.flatMap { $0.token }
        switch keychainToken {
        case .value:
            yamlToken = nil
            placement = .unchanged
        case .absent:
            if let inline = existingToken {
                yamlToken = nil
                placement = .keychain(inline)
            } else if let legacy = sync.token {
                yamlToken = nil
                placement = .keychain(legacy)
            } else {
                yamlToken = nil
                placement = .unchanged
            }
        case .failed:
            yamlToken = existingToken
            placement = .unchanged
        }

        return MergedServer(
            config: ServerConfig(
                url: sync.url,
                token: yamlToken,
                topics: topics,
                allowedSchemes: sync.allowedSchemes,
                allowedDomains: sync.allowedDomains,
                fetchMissed: sync.fetchMissed
            ),
            tokenPlacement: placement
        )
    }

    /// Synced fields come from the merged document, machine-local ones (icon and script
    /// paths, notification actions) stay exactly as this Mac has them.
    private static func merge(topic sync: SyncTopic, into existing: TopicConfig?) -> TopicConfig {
        TopicConfig(
            name: sync.name,
            iconPath: existing?.iconPath,
            iconSymbol: sync.iconSymbol,
            autoRunScript: existing?.autoRunScript,
            autoRunScriptArgs: existing?.autoRunScriptArgs,
            silent: sync.silent,
            clickUrl: sync.clickUrl,
            actions: existing?.actions,
            fetchMissed: sync.fetchMissed
        )
    }
}
