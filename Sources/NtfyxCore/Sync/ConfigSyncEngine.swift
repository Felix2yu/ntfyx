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
        /// Read after the push, never before: an atomic rewrite always refreshes mtime, so
        /// a marker captured earlier would make the next poll see our own write as a remote edit.
        public var cloudFingerprint: String?
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
        var tokenUnreadable = false
        let effectiveToken: (String) -> String? = { serverURL in
            switch keychainToken(serverURL) {
            case .value(let token):
                return token
            case .absent:
                return config.server(forURL: serverURL)?.token
            case .failed:
                tokenUnreadable = true
                return config.server(forURL: serverURL)?.token
            }
        }
        let localDocument = ConfigSyncTranslator.document(from: config, effectiveToken: effectiveToken)
        guard !tokenUnreadable else { throw ConfigSyncError.keychainUnreadable }

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

        var wroteCloud = false
        if merged != cloudDocument {
            try store.write(merged)
            wroteCloud = true
        }

        var wroteLocal = false
        if localDocument != merged {
            try applyToLocal(merged, preserving: config, keychainToken: keychainToken, saveLocal: saveLocal, storeToken: storeToken)
            wroteLocal = true
        }

        if !mergedConflicts.isEmpty {
            store.deleteConflictCopies(mergedConflicts)
        }

        return Outcome(
            merged: merged,
            cloudFingerprint: store.cloudFingerprint(),
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
        case .removeFromKeychain:
            try? KeychainHelper.deleteToken(forServer: serverURL)
        case .inline, .unchanged:
            break  // carried by the YAML field the local write produces
        }
    }

    /// Writes the merged document into this Mac's own file, keeping the token representation
    /// this machine already used for each server.
    static func applyToLocal(
        _ merged: SyncDocument,
        preserving local: AppConfig,
        keychainToken: (String) -> KeychainTokenReader.Outcome,
        saveLocal: (AppConfig) throws -> Void,
        storeToken: (String, ConfigSyncTranslator.TokenPlacement) -> Void
    ) throws {
        let write = ConfigSyncTranslator.localWrite(from: merged, preserving: local, keychainToken: keychainToken)
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
