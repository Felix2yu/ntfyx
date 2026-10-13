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
    /// Where a merged server's token ends up on this Mac. A server keeps the representation
    /// it already had, so a sync never quietly moves a credential between the YAML file and
    /// the Keychain.
    public enum TokenPlacement: Equatable {
        case unchanged
        case keychain(String)
        case removeFromKeychain
        case inline(String?)
    }

    struct LocalWrite {
        var config: AppConfig
        var tokenPlacements: [String: TokenPlacement] = [:]
    }

    /// The local file plus the token this Mac actually subscribes with — the cloud copy has
    /// to carry that, or the other Macs get a server they cannot reach.
    static func document(
        from config: AppConfig,
        effectiveToken: (String) -> String?
    ) -> SyncDocument {
        SyncDocument(servers: config.servers.map { server in
            SyncServer(
                url: server.url,
                token: effectiveToken(server.url),
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

        let yamlToken: String?
        let placement: TokenPlacement
        let existingToken = existing.flatMap { $0.token }
        switch (keychainToken, existing?.token) {
        case (.value(let stored), _):
            // Keychain-backed: the credential stays out of the YAML, and the entry is only
            // rewritten when the merged value differs from what is already stored.
            yamlToken = existingToken
            placement = stored == sync.token ? .unchanged
                : (sync.token.map { TokenPlacement.keychain($0) } ?? .removeFromKeychain)
        case (.absent, let inline?):
            // Inline-backed: the YAML field carries it.
            yamlToken = sync.token
            placement = inline == sync.token ? .unchanged : .inline(sync.token)
        case (.absent, nil):
            // Nothing stored locally: a token arriving from the cloud belongs in the
            // Keychain, not in a plaintext file.
            yamlToken = nil
            placement = sync.token.map { TokenPlacement.keychain($0) } ?? .unchanged
        case (.failed, _):
            // The Keychain could not be read, so nothing about this server is touched.
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
            silent: sync.silent,
            clickUrl: sync.clickUrl,
            actions: existing?.actions,
            fetchMissed: sync.fetchMissed
        )
    }
}
