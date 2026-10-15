import Foundation

/// One merge-and-converge pass, shared by the running service and the one-shot CLI so the
/// two cannot grow different ideas of what "synced" means.
///
/// Both sides always end up holding the merged result. Applying it to only one side while
/// advancing `base` would make the next pass read the other side's older state as a
/// deletion, which is how a sync eats a subscription.
public enum ConfigSyncEngine {
    public struct Outcome: Sendable {
        public var merged: SyncDocument
        public var wroteCloud = false
        public var wroteLocal = false
        public var conflictCopiesMerged = 0
        public var servers: Int
        public var topics: Int
    }

    public static func run(
        local config: AppConfig,
        base: SyncDocument,
        resolution: ConfigMerger.ConflictResolution,
        store: CloudConfigStore,
        keychainToken: (String) -> KeychainTokenReader.Outcome = KeychainTokenReader.read,
        saveLocal: (AppConfig) throws -> Void = { config in
            _ = try ConfigFile.write(config)
        },
        storeToken: (String, ConfigSyncTranslator.TokenPlacement) -> Void = ConfigSyncEngine.writeToken
    ) throws -> Outcome {
        // Cloud documents are token-free: publishing needs no Keychain read.
        let localDocument = ConfigSyncTranslator.document(from: config)

        let cloudDocument = try store.readCloud() ?? .empty
        var merged = ConfigMerger.merge(base: base, local: localDocument, cloud: cloudDocument, conflictResolution: resolution)

        // Conflict copies are edits iCloud Drive could not merge. They are read as further
        // cloud versions, then removed once their contents are safely in the merged result.
        var mergedConflicts: [URL] = []
        for url in store.conflictCopies() {
            do {
                guard let copy = try store.read(at: url) else { continue }
                merged = ConfigMerger.merge(base: base, local: merged, cloud: copy, conflictResolution: .stableFingerprint)
                mergedConflicts.append(url)
            } catch {
                // Still an iCloud placeholder, or unreadable: leave it for the next pass.
            }
        }

        // A Keychain read that failed must not be mistaken for "no token stored" while the
        // local write decides placements; that would migrate or backfill credentials based
        // on a guess. Abort before touching either side, same as the preflight used to do
        // during document publishing.
        for server in merged.servers where keychainToken(server.url) == .failed {
            throw ConfigSyncError.keychainUnreadable
        }

        // Cloud-facing copy: defence in depth that a decoded v1 token can never be written
        // back to the shared file. The token-carrying `merged` below still drives the
        // one-time Keychain backfill in `applyToLocal`.
        let cloudReady = merged.strippingLegacyTokens

        var wroteCloud = false
        if cloudReady != cloudDocument {
            precondition(
                cloudReady.servers.allSatisfy { $0.token == nil },
                "cloud configuration must never contain a server token"
            )
            try store.write(cloudReady)
            wroteCloud = true
        }

        // Plan the local write even when the documents already converge: a v1 token
        // backfill or an inline→Keychain migration changes no subscription but still has
        // to land, so the gate is the resulting file plus the Keychain side effects —
        // not the token-free document comparison above.
        let planned = ConfigSyncTranslator.localWrite(
            from: merged, preserving: config, keychainToken: keychainToken
        )
        var wroteLocal = false
        if planned.config != config || !planned.tokenPlacements.isEmpty {
            try apply(planned, saveLocal: saveLocal, storeToken: storeToken)
            wroteLocal = true
        }

        if !mergedConflicts.isEmpty {
            store.deleteConflictCopies(mergedConflicts)
        }

        return Outcome(
            merged: cloudReady,
            wroteCloud: wroteCloud,
            wroteLocal: wroteLocal,
            conflictCopiesMerged: mergedConflicts.count,
            servers: merged.servers.count,
            topics: merged.topicCount
        )
    }

    /// Where a token belongs on this Mac. Both side effects of a pass are parameters rather
    /// than shared state so the orchestration can be exercised without touching this Mac's
    /// real config file or Keychain.
    public static func writeToken(_ serverURL: String, _ placement: ConfigSyncTranslator.TokenPlacement) {
        switch placement {
        case .keychain(let token):
            try? KeychainHelper.saveToken(token, forServer: serverURL)
        case .unchanged:
            break
        }
    }

    /// Persists a planned local write: Keychain side effects first, then the YAML file.
    static func apply(
        _ write: ConfigSyncTranslator.LocalWrite,
        saveLocal: (AppConfig) throws -> Void,
        storeToken: (String, ConfigSyncTranslator.TokenPlacement) -> Void
    ) throws {
        for (serverURL, placement) in write.tokenPlacements {
            storeToken(serverURL, placement)
        }

        do {
            try saveLocal(write.config)
        } catch {
            throw ConfigSyncError.localWriteFailed(error.localizedDescription)
        }
    }
}
