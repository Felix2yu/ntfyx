import Foundation

/// Three-way merge of the cloud configuration: `base` is the state every Mac agreed on
/// last, `local` this Mac's current file, `cloud` the shared file. Servers are keyed by
/// URL and topics by name, so subscriptions added on any device survive; a field only one
/// side touched takes that side's value.
///
/// For a field both sides changed to *different* values the two candidates have to be
/// picked the same way on every Mac, otherwise each device keeps pushing its own favourite
/// and the file oscillates. Hence `stableHash`: the candidates are a set every device sees,
/// and comparing their fingerprints is symmetric. Deleting an entity wins over editing it
/// on the other side — a subscription the user removed should not come back to life.
public enum ConfigMerger {
    public enum ConflictResolution {
        /// Both sides changed the same field: pick deterministically so all devices converge.
        case stableFingerprint
        /// First sync of a Mac that never agreed on `cloud` yet: its own settings are the
        /// newest edit, so they win over values it merely never had.
        case preferLocal
        /// `ntfyxctl sync pull` — the user said this time the cloud value is the one to keep.
        case preferCloud
    }

    static func merge(
        base: SyncDocument,
        local: SyncDocument,
        cloud: SyncDocument,
        conflictResolution: ConflictResolution = .stableFingerprint
    ) -> SyncDocument {
        let baseIndex = base.serverIndex, localIndex = local.serverIndex, cloudIndex = cloud.serverIndex
        let urls = Set(localIndex.keys).union(cloudIndex.keys).sorted()

        var merged: [SyncServer] = []
        for url in urls {
            if let server = mergeServer(
                base: baseIndex[url],
                local: localIndex[url],
                cloud: cloudIndex[url],
                conflictResolution: conflictResolution
            ) {
                merged.append(server)
            }
        }
        return SyncDocument(servers: merged).pruningEmptyServers.canonicalized
    }

    private static func mergeServer(
        base: SyncServer?,
        local: SyncServer?,
        cloud: SyncServer?,
        conflictResolution: ConflictResolution
    ) -> SyncServer? {
        switch (local, cloud) {
        case (nil, nil):
            return nil
        case (.some, nil), (nil, .some):
            // Present on one side only: a deletion by the other side wins, but when the
            // entity never was in `base` whoever has it simply added a subscription.
            guard base == nil else { return nil }
            return local ?? cloud
        case (let local?, let cloud?):
            let topics = mergeTopics(
                base: base?.topicIndex ?? [:],
                local: local.topicIndex,
                cloud: cloud.topicIndex,
                names: Set(local.topicIndex.keys).union(cloud.topicIndex.keys).sorted(),
                conflictResolution: conflictResolution
            )
            return SyncServer(
                url: local.url,
                // Tokens are not a merge dimension (E2a). A v1 cloud file's token only
                // rides along here so the local write can backfill this Mac's Keychain once.
                token: cloud.token,
                topics: topics,
                allowedSchemes: pick(base: base?.allowedSchemes, local: local.allowedSchemes, cloud: cloud.allowedSchemes, conflictResolution: conflictResolution),
                allowedDomains: pick(base: base?.allowedDomains, local: local.allowedDomains, cloud: cloud.allowedDomains, conflictResolution: conflictResolution),
                fetchMissed: pick(base: base?.fetchMissed, local: local.fetchMissed, cloud: cloud.fetchMissed, conflictResolution: conflictResolution)
            )
        }
    }

    private static func mergeTopics(
        base: [String: SyncTopic],
        local: [String: SyncTopic],
        cloud: [String: SyncTopic],
        names: [String],
        conflictResolution: ConflictResolution
    ) -> [SyncTopic] {
        var topics: [SyncTopic] = []
        for name in names {
            let topic = mergeTopic(
                base: base[name],
                local: local[name],
                cloud: cloud[name],
                conflictResolution: conflictResolution
            )
            if let topic { topics.append(topic) }
        }
        return topics
    }

    private static func mergeTopic(
        base: SyncTopic?,
        local: SyncTopic?,
        cloud: SyncTopic?,
        conflictResolution: ConflictResolution
    ) -> SyncTopic? {
        switch (local, cloud) {
        case (nil, nil):
            return nil
        case (.some, nil), (nil, .some):
            guard base == nil else { return nil }
            return local ?? cloud
        case (let local?, let cloud?):
            return SyncTopic(
                name: local.name,
                iconSymbol: pick(base: base?.iconSymbol, local: local.iconSymbol, cloud: cloud.iconSymbol, conflictResolution: conflictResolution),
                silent: pick(base: base?.silent, local: local.silent, cloud: cloud.silent, conflictResolution: conflictResolution),
                clickUrl: pick(base: base?.clickUrl, local: local.clickUrl, cloud: cloud.clickUrl, conflictResolution: conflictResolution),
                fetchMissed: pick(base: base?.fetchMissed, local: local.fetchMissed, cloud: cloud.fetchMissed, conflictResolution: conflictResolution)
            )
        }
    }

    /// One side's change wins; both sides' differing changes are broken by
    /// `conflictResolution`.
    private static func pick<T: Codable & Equatable>(
        base: T?,
        local: T?,
        cloud: T?,
        conflictResolution: ConflictResolution
    ) -> T? {
        if local == cloud { return local }

        let localChanged = local != base
        let cloudChanged = cloud != base
        if localChanged != cloudChanged {
            return localChanged ? local : cloud
        }

        switch conflictResolution {
        case .preferLocal:
            return local
        case .preferCloud:
            return cloud
        case .stableFingerprint:
            return SyncFingerprint.of(local) >= SyncFingerprint.of(cloud) ? local : cloud
        }
    }
}
