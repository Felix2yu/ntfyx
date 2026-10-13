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
                     save: @escaping (AppConfig) -> Void = { _ in }) throws -> ConfigSyncEngine.Outcome {
        try ConfigSyncEngine.run(local: local, base: base, resolution: resolution, store: store,
                                 keychainToken: { _ in keychain }, saveLocal: fakeSave(save),
                                 storeToken: { _, _ in })
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

    func testFingerprintDescribesTheFileJustWritten() throws {
        // The service stores this value and the poll compares it on the next tick; if it
        // described the pre-write file, every poll would redo the whole merge.
        let outcome = try run(base: .empty, local: localConfig(["alerts"]), resolution: .preferLocal)
        XCTAssertEqual(store.cloudFingerprint(), outcome.cloudFingerprint)
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

    // MARK: - Conflict copies

    func testReadableConflictCopyIsMergedThenRemoved() throws {
        let base = try run(base: .empty, local: localConfig(["alerts"]), resolution: .preferLocal).merged
        let copy = SyncDocument(servers: [SyncServer(url: "https://c.example", topics: [syncTopic("via-conflict")])])
        let copyURL = directory.appendingPathComponent("config 冲突副本 Macmini.yml")
        try CloudConfigStore.encoded(copy).write(to: copyURL, atomically: true, encoding: .utf8)

        let outcome = try run(base: base, local: localConfig(["alerts"]))

        XCTAssertEqual(outcome.conflictCopiesMerged, 1)
        XCTAssertEqual(outcome.merged.serverIndex["https://c.example"]?.topics.map(\.name), ["via-conflict"],
                       "冲突副本里的订阅不能丢")
        XCTAssertTrue(store.conflictCopies().isEmpty, "合并过的副本才被清理")
    }

    func testUnreadableConflictCopyStaysForTheNextPass() throws {
        let base = try run(base: .empty, local: localConfig(["alerts"]), resolution: .preferLocal).merged
        let copyURL = directory.appendingPathComponent("config conflicting copy.yml")
        try "version: 99\nservers: []\n".write(to: copyURL, atomically: true, encoding: .utf8)

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
