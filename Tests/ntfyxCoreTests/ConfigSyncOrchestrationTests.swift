import XCTest
@testable import NtfyxCore

/// One merge-and-converge pass end to end. These exercise the orchestration — which side
/// gets written, what happens when nothing changed, and the two ways a pass can stop early —
/// against a temporary folder, with the real config file and Keychain kept out of it.
final class ConfigSyncOrchestrationTests: XCTestCase {
    private let url = "https://a.example"

    private var directory: URL!
    private var store: CloudConfigStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ntfyx-engine-\(UUID().uuidString)")
        store = CloudConfigStore(directoryOverride: directory.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func syncTopic(_ name: String) -> SyncTopic { SyncTopic(name: name) }

    private func syncServer(_ url: String, topics: [SyncTopic]) -> SyncServer {
        SyncServer(url: url, topics: topics)
    }

    private func localConfig(_ topics: [String]) -> AppConfig {
        AppConfig(servers: [ServerConfig(url: url, topics: topics.map { TopicConfig(name: $0) })])
    }

    /// Records instead of writing, so a pass cannot touch this Mac.
    private func fakeSave(_ sink: @escaping (AppConfig) -> Void) -> (AppConfig) throws -> Void {
        return { config in sink(config) }
    }

    private func run(base: SyncDocument, local: AppConfig,
                     resolution: ConfigMerger.ConflictResolution = .stableFingerprint,
                     keychain: KeychainTokenReader.Outcome = .absent,
                     save: @escaping (AppConfig) -> Void = { _ in },
                     tokenSink: @escaping (String, ConfigSyncTranslator.TokenPlacement) -> Void = { _, _ in }) throws -> ConfigSyncEngine.Outcome {
        try ConfigSyncEngine.run(local: local, base: base, resolution: resolution, store: store,
                                 keychainToken: { _ in keychain }, saveLocal: fakeSave(save),
                                 storeToken: tokenSink)
    }

    private func writeRawCloud(_ text: String) throws {
        try store.prepare()
        try text.write(to: store.cloudFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - A single Mac joining

    func testFirstPassPublishesLocalConfigWithoutRewritingIt() throws {
        var saved: AppConfig?
        let outcome = try run(base: .empty, local: localConfig(["alerts"]), resolution: .preferLocal) { saved = $0 }

        XCTAssertTrue(outcome.wroteCloud, "本机配置写上云端")
        XCTAssertFalse(outcome.wroteLocal, "云端没有新东西，本地文件不该被动重写")
        XCTAssertNil(saved)
    }

    func testSecondPassWithNothingChangedWritesNeitherSide() throws {
        let first = try run(base: .empty, local: localConfig(["alerts"]), resolution: .preferLocal)

        let again = try run(base: first.merged, local: localConfig(["alerts"]))
        XCTAssertFalse(again.wroteCloud)
        XCTAssertFalse(again.wroteLocal)
    }

    func testConvergedPassProducesNoDiffOnEitherSide() throws {
        // E2b removed the poll fingerprint entirely; idempotence now rests on the engine
        // comparing the token-free documents: a converged state rewrites neither file.
        let first = try run(base: .empty, local: localConfig(["alerts"]), resolution: .preferLocal)
        let again = try run(base: first.merged, local: localConfig(["alerts"]))
        XCTAssertEqual(again.merged, first.merged)
    }

    // MARK: - Other device's edits

    func testCloudAdditionLandsLocallyAndIsNotPushedBack() throws {
        let base = try run(base: .empty, local: localConfig(["alerts"]), resolution: .preferLocal).merged
        try store.write(SyncDocument(servers: [syncServer(url, topics: [syncTopic("alerts"), syncTopic("other-mac")])]))

        var saved: AppConfig?
        let outcome = try run(base: base, local: localConfig(["alerts"])) { saved = $0 }

        XCTAssertTrue(outcome.wroteLocal)
        XCTAssertFalse(outcome.wroteCloud, "云端已是合并结果，不该再写一次")
        XCTAssertEqual(saved?.servers.first?.topics.map(\.name), ["alerts", "other-mac"])
    }

    func testBothSidesAddedTopicsUpdatesBothFiles() throws {
        let base = try run(base: .empty, local: localConfig(["alerts"]), resolution: .preferLocal).merged
        try store.write(SyncDocument(servers: [syncServer(url, topics: [syncTopic("alerts"), syncTopic("cloud-only")])]))

        var saved: AppConfig?
        let outcome = try run(base: base, local: localConfig(["alerts", "local-only"])) { saved = $0 }

        XCTAssertTrue(outcome.wroteCloud)
        XCTAssertTrue(outcome.wroteLocal)
        XCTAssertEqual(saved?.servers.first?.topics.map(\.name), ["alerts", "local-only", "cloud-only"],
                       "本机原有顺序在前，云端独有的排在后面")
    }

    // MARK: - Stopping early

    func testUnreadableKeychainAbortsTheWholePass() throws {
        // A token that could not be read must never be published as "no token".
        try store.write(SyncDocument(servers: [syncServer(url, topics: [syncTopic("alerts")])]))
        let base = try store.readCloud() ?? .empty

        var saved: AppConfig?
        let record: (AppConfig) -> Void = { saved = $0 }
        XCTAssertThrowsError(try run(base: base, local: localConfig(["alerts"]), resolution: .preferLocal,
                                     keychain: .failed, save: record)) { error in
            guard case ConfigSyncError.keychainUnreadable = error else {
                return XCTFail("应因钥匙串读不到而中止，实际为 \(error)")
            }
        }
        XCTAssertNil(saved)
        XCTAssertEqual(try store.readCloud(), base, "云端文件保持原样")
    }

    // MARK: - Token handling (E2a)

    func testV1CloudTokenIsBackfilledIntoKeychainAndStrippedFromCloud() throws {
        // A v1-era cloud file (plaintext token) landing on a Mac whose Keychain is empty:
        // the credential is recovered into the Keychain once, the YAML stays token-free,
        // and the shared file is rewritten as token-free v2.
        try writeRawCloud("""
        version: 1
        servers:
          - url: \(url)
            token: v1-secret
            topics:
              - name: alerts
        """)

        var saved: AppConfig?
        var placements: [String: ConfigSyncTranslator.TokenPlacement] = [:]
        let outcome = try run(base: .empty, local: localConfig(["alerts"]), resolution: .preferLocal,
                              save: { saved = $0 },
                              tokenSink: { placements[$0] = $1 })

        XCTAssertEqual(placements[url], .keychain("v1-secret"))
        XCTAssertNil(saved?.servers.first?.token, "回填只进钥匙串，本地 YAML 不落令牌")
        XCTAssertTrue(outcome.wroteCloud)

        let cloudText = try String(contentsOf: store.cloudFileURL, encoding: .utf8)
        XCTAssertFalse(cloudText.contains("v1-secret"))
        XCTAssertFalse(cloudText.contains("token"))
        XCTAssertTrue(cloudText.contains("version: 2"))

        // Second pass with the token now in the Keychain: nothing moves anymore.
        var secondSaved = false
        var secondPlacements: [String: ConfigSyncTranslator.TokenPlacement] = [:]
        let again = try run(base: outcome.merged, local: localConfig(["alerts"]),
                            keychain: .value("v1-secret"),
                            save: { _ in secondSaved = true },
                            tokenSink: { secondPlacements[$0] = $1 })
        XCTAssertFalse(again.wroteCloud)
        XCTAssertFalse(again.wroteLocal)
        XCTAssertFalse(secondSaved)
        XCTAssertTrue(secondPlacements.isEmpty)
    }

    func testKeychainTokenIsNeverOverwrittenByALegacyCloudToken() throws {
        try writeRawCloud("""
        version: 1
        servers:
          - url: \(url)
            token: stale-cloud-token
            topics:
              - name: alerts
        """)

        var placements: [String: ConfigSyncTranslator.TokenPlacement] = [:]
        _ = try run(base: .empty, local: localConfig(["alerts"]), resolution: .preferLocal,
                    keychain: .value("the-real-token"),
                    tokenSink: { placements[$0] = $1 })
        XCTAssertTrue(placements.isEmpty, "钥匙串已有值时，旧云令牌不得覆盖")
    }

    func testInlineYamlTokenMigratesToKeychainOnInboundChange() throws {
        // First the shared file exists token-free (written by another Mac)…
        try store.prepare()
        try store.write(SyncDocument(servers: [syncServer(url, topics: [syncTopic("alerts"),
                                                                         syncTopic("cloud-only")])]))
        let base = try store.readCloud() ?? .empty

        // …this Mac still carries its credential inline and also added a local topic.
        let local = AppConfig(servers: [ServerConfig(
            url: url, token: "inline-tk",
            topics: [TopicConfig(name: "alerts"), TopicConfig(name: "local-only")]
        )])

        var saved: AppConfig?
        var placements: [String: ConfigSyncTranslator.TokenPlacement] = [:]
        let outcome = try run(base: base, local: local,
                              save: { saved = $0 },
                              tokenSink: { placements[$0] = $1 })

        XCTAssertEqual(placements[url], .keychain("inline-tk"))
        XCTAssertNil(saved?.servers.first?.token, "迁移后写回的 YAML 已清空令牌")
        let cloudText = try String(contentsOf: store.cloudFileURL, encoding: .utf8)
        XCTAssertFalse(cloudText.contains("inline-tk"))
        XCTAssertTrue(outcome.wroteCloud)
    }

    // MARK: - Conflict copies

    func testReadableConflictVersionIsMergedThenRemoved() throws {
        let base = try run(base: .empty, local: localConfig(["alerts"]), resolution: .preferLocal).merged
        let copy = SyncDocument(servers: [SyncServer(url: "https://c.example", topics: [syncTopic("via-conflict")])])
        let copyURL = directory.appendingPathComponent("config (a conflict version).yml")
        try CloudConfigStore.encoded(copy).write(to: copyURL, atomically: true, encoding: .utf8)
        // The NSFileVersion seam: a version URL exists on disk only until it is resolved.
        store.listConflictVersions = { _ in
            FileManager.default.fileExists(atPath: copyURL.path) ? [copyURL] : []
        }

        let outcome = try run(base: base, local: localConfig(["alerts"]))

        XCTAssertEqual(outcome.conflictCopiesMerged, 1)
        XCTAssertEqual(outcome.merged.serverIndex["https://c.example"]?.topics.map(\.name), ["via-conflict"],
                       "冲突版本里的订阅不能丢")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path))
        XCTAssertTrue(store.conflictCopies().isEmpty, "合并过的版本才被清理")
    }

    func testUnreadableConflictVersionStaysForTheNextPass() throws {
        let base = try run(base: .empty, local: localConfig(["alerts"]), resolution: .preferLocal).merged
        let copyURL = directory.appendingPathComponent("config (a conflict version).yml")
        try "version: 99\nservers: []\n".write(to: copyURL, atomically: true, encoding: .utf8)
        store.listConflictVersions = { _ in
            FileManager.default.fileExists(atPath: copyURL.path) ? [copyURL] : []
        }

        let outcome = try run(base: base, local: localConfig(["alerts"]))

        XCTAssertEqual(outcome.conflictCopiesMerged, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path))
    }

    // MARK: - Direction asked for on the command line

    func testPullPrefersTheCloudOnAConflict() {
        let base = SyncDocument(servers: [SyncServer(url: url, topics: [SyncTopic(name: "alerts", iconSymbol: "bell")])])
        let local = SyncDocument(servers: [SyncServer(url: url, topics: [SyncTopic(name: "alerts", iconSymbol: "hammer")])])
        let cloud = SyncDocument(servers: [SyncServer(url: url, topics: [SyncTopic(name: "alerts", iconSymbol: "star")])])

        XCTAssertEqual(ConfigMerger.merge(base: base, local: local, cloud: cloud, conflictResolution: .preferCloud)
                       .serverIndex[url]?.topicIndex["alerts"]?.iconSymbol, "star")
    }

    func testPushPrefersThisMacOnAConflict() {
        let base = SyncDocument(servers: [SyncServer(url: url, topics: [SyncTopic(name: "alerts", iconSymbol: "bell")])])
        let local = SyncDocument(servers: [SyncServer(url: url, topics: [SyncTopic(name: "alerts", iconSymbol: "hammer")])])
        let cloud = SyncDocument(servers: [SyncServer(url: url, topics: [SyncTopic(name: "alerts", iconSymbol: "star")])])

        XCTAssertEqual(ConfigMerger.merge(base: base, local: local, cloud: cloud, conflictResolution: .preferLocal)
                       .serverIndex[url]?.topicIndex["alerts"]?.iconSymbol, "hammer")
    }
}
