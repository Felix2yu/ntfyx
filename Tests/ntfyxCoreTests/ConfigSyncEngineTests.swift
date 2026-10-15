import XCTest
import Yams
@testable import NtfyxCore

/// Three-way merge of the cloud configuration. The two properties that matter most are
/// that a subscription added on any Mac survives, and that every Mac arrives at the *same*
/// merged document — a sync that resolves conflicts differently per device pushes the file
/// back and forth forever.
final class ConfigSyncEngineTests: XCTestCase {

    private func topic(_ name: String, iconSymbol: String? = nil, silent: Bool? = nil,
                       clickUrl: ClickUrlConfig? = nil, fetchMissed: Bool? = nil) -> SyncTopic {
        SyncTopic(name: name, iconSymbol: iconSymbol, silent: silent, clickUrl: clickUrl, fetchMissed: fetchMissed)
    }

    private func server(_ url: String, token: String? = nil, topics: [SyncTopic],
                        schemes: [String]? = nil, domains: [String]? = nil, fetchMissed: Bool? = nil) -> SyncServer {
        SyncServer(url: url, token: token, topics: topics, allowedSchemes: schemes, allowedDomains: domains, fetchMissed: fetchMissed)
    }

    private func doc(_ servers: [SyncServer]) -> SyncDocument {
        SyncDocument(servers: servers)
    }

    // MARK: - Additions

    func testTopicAddedOnlyLocallySurvives() {
        let base = doc([server("https://a.example", topics: [topic("alerts")])])
        let local = doc([server("https://a.example", topics: [topic("alerts"), topic("builds")])])
        let merged = ConfigMerger.merge(base: base, local: local, cloud: base)

        XCTAssertEqual(merged.servers.first?.topics.map(\.name), ["alerts", "builds"])
    }

    func testTopicAddedOnlyInCloudSurvives() {
        let base = doc([server("https://a.example", topics: [topic("alerts")])])
        let cloud = doc([server("https://a.example", topics: [topic("alerts"), topic("builds")])])
        let merged = ConfigMerger.merge(base: base, local: base, cloud: cloud)

        XCTAssertEqual(merged.servers.first?.topics.map(\.name), ["alerts", "builds"])
    }

    func testServerAddedOnEitherSideSurvives() {
        let base = doc([server("https://a.example", topics: [topic("alerts")])])
        let local = doc([server("https://a.example", topics: [topic("alerts")]),
                         server("https://local.example", topics: [topic("home")])])
        let cloud = doc([server("https://a.example", topics: [topic("alerts")]),
                         server("https://cloud.example", topics: [topic("work")])])
        let merged = ConfigMerger.merge(base: base, local: local, cloud: cloud)

        XCTAssertEqual(merged.servers.map(\.url), ["https://a.example", "https://cloud.example", "https://local.example"])
    }

    // MARK: - Deletions

    func testLocalDeletionPropagates() {
        let base = doc([server("https://a.example", topics: [topic("alerts"), topic("builds")])])
        let local = doc([server("https://a.example", topics: [topic("alerts")])])
        let merged = ConfigMerger.merge(base: base, local: local, cloud: base)

        XCTAssertEqual(merged.servers.first?.topics.map(\.name), ["alerts"])
    }

    func testCloudDeletionPropagatesAndBeatsAConcurrentEdit() {
        let base = doc([server("https://a.example", topics: [topic("alerts"), topic("builds")])])
        let local = doc([server("https://a.example", topics: [topic("alerts"), topic("builds", iconSymbol: "hammer")])])
        let cloud = doc([server("https://a.example", topics: [topic("alerts")])])
        let merged = ConfigMerger.merge(base: base, local: local, cloud: cloud)

        // A subscription the user removed must not come back because another Mac renamed
        // its icon; the other direction would resurrect deleted topics on every sync.
        XCTAssertEqual(merged.servers.first?.topics.map(\.name), ["alerts"])
    }

    func testServerDeletedOnOneSideDisappears() {
        let base = doc([server("https://a.example", topics: [topic("alerts")]),
                        server("https://gone.example", topics: [topic("old")])])
        let local = doc([server("https://a.example", topics: [topic("alerts")])])
        let merged = ConfigMerger.merge(base: base, local: local, cloud: base)

        XCTAssertEqual(merged.servers.map(\.url), ["https://a.example"])
    }

    // MARK: - Field resolution

    func testFieldChangedOnOneSideOnlyTakesThatSide() {
        let base = doc([server("https://a.example", topics: [topic("alerts", silent: false)])])
        let local = doc([server("https://a.example", topics: [topic("alerts", silent: true)])])
        let cloud = doc([server("https://a.example", topics: [topic("alerts", silent: false)], fetchMissed: true)])

        let merged = ConfigMerger.merge(base: base, local: local, cloud: cloud)
        XCTAssertEqual(merged.servers.first?.topics.first?.silent, true)
        XCTAssertEqual(merged.servers.first?.fetchMissed, true)
    }

    func testDifferingEditsResolveIdenticallyFromEitherPerspective() {
        let base = doc([server("https://a.example", topics: [topic("alerts", iconSymbol: "bell")])])
        let left = doc([server("https://a.example", topics: [topic("alerts", iconSymbol: "hammer")])])
        let right = doc([server("https://a.example", topics: [topic("alerts", iconSymbol: "star")])])

        let fromLeft = ConfigMerger.merge(base: base, local: left, cloud: right)
        let fromRight = ConfigMerger.merge(base: base, local: right, cloud: left)

        XCTAssertEqual(fromLeft, fromRight, "both Macs must pick the same icon or the file oscillates")
        XCTAssertNotNil(fromLeft.servers.first?.topics.first?.iconSymbol)
    }

    func testUnchangedOnBothSidesStaysUnchanged() {
        let shared = doc([server("https://a.example", token: "tk", topics: [topic("alerts", silent: false)])])
        XCTAssertEqual(ConfigMerger.merge(base: shared, local: shared, cloud: shared), shared)
    }

    func testMergeIsStableUnderRepetition() {
        let base = doc([server("https://a.example", topics: [topic("alerts")])])
        let local = doc([server("https://a.example", topics: [topic("alerts"), topic("builds")]),
                         server("https://b.example", topics: [topic("only-local")])])
        let cloud = doc([server("https://a.example", topics: [topic("alerts", iconSymbol: "bell")]),
                         server("https://c.example", topics: [topic("only-cloud")])])

        let merged = ConfigMerger.merge(base: base, local: local, cloud: cloud)
        let again = ConfigMerger.merge(base: merged, local: merged, cloud: merged)
        XCTAssertEqual(merged, again)
    }

    func testTwoDeviceRoundTripConverges() {
        // A and B start from the same ancestor, both edit, then each publishes what it has.
        // After B pulls A's file the two documents must be equal, otherwise the next push
        // from either side would change the cloud file again — forever.
        let base = doc([server("https://a.example", topics: [topic("alerts")])])
        let deviceA = doc([server("https://a.example", token: "tk-a", topics: [topic("alerts"), topic("a-only")])])
        let deviceB = doc([server("https://a.example", topics: [topic("alerts", silent: true), topic("b-only")])])

        let aFirst = ConfigMerger.merge(base: base, local: deviceA, cloud: deviceB)
        let bAfter = ConfigMerger.merge(base: base, local: deviceB, cloud: aFirst)

        XCTAssertEqual(aFirst, bAfter)
        XCTAssertEqual(Set(aFirst.servers.first!.topics.map(\.name)), ["alerts", "a-only", "b-only"])
    }

    // MARK: - Joining an existing cloud file

    func testFirstSyncAdoptsCloudTopicsAndPrefersLocalFieldValues() {
        let cloud = doc([server("https://a.example", topics: [topic("alerts", iconSymbol: "bell"), topic("work")])])
        let local = doc([server("https://a.example", topics: [topic("alerts", iconSymbol: "hammer"), topic("home")])])

        let merged = ConfigMerger.merge(base: .empty, local: local, cloud: cloud, conflictResolution: .preferLocal)

        XCTAssertEqual(Set(merged.servers.first!.topics.map(\.name)), ["alerts", "home", "work"])
        // The Mac joining has genuinely just set its own icon; the cloud value is one it
        // never had, so it is not evidence that the other device is more recent.
        XCTAssertEqual(merged.serverIndex["https://a.example"]?.topicIndex["alerts"]?.iconSymbol, "hammer")
    }

    func testFirstSyncWithEmptyCloudPublishesLocalConfig() {
        let local = doc([server("https://a.example", topics: [topic("alerts")])])
        XCTAssertEqual(ConfigMerger.merge(base: .empty, local: local, cloud: .empty), local)
    }

    // MARK: - Normalisation

    func testEmptyServersArePruned() {
        let base = doc([server("https://a.example", topics: [topic("alerts")])])
        let local = doc([server("https://a.example", topics: []),
                         server("https://b.example", topics: [topic("keep")])])
        let merged = ConfigMerger.merge(base: base, local: local, cloud: base)

        XCTAssertEqual(merged.servers.map(\.url), ["https://b.example"])
    }

    func testOutputIsCanonicallyOrdered() {
        let unordered = doc([server("https://z.example", topics: [topic("zebra"), topic("alpha")]),
                            server("https://a.example", topics: [topic("mid")])])
        XCTAssertEqual(unordered.canonicalized.servers.map(\.url), ["https://a.example", "https://z.example"])
        XCTAssertEqual(unordered.canonicalized.serverIndex["https://z.example"]?.topics.map(\.name), ["alpha", "zebra"])
    }

    // MARK: - Tokens (E2a)

    func testDocumentsDifferingOnlyInTokenAreEqual() {
        let without = doc([server("https://a.example", topics: [topic("alerts")])])
        let withLegacy = doc([server("https://a.example", token: "v1-token", topics: [topic("alerts")])])
        XCTAssertEqual(without, withLegacy, "解码出的 v1 令牌不参与文档同一性")
    }

    func testMergeCarriesLegacyCloudTokenTransientlyButIgnoresItAsAField() {
        let base = doc([server("https://a.example", token: "old", topics: [topic("alerts")])])
        let local = doc([server("https://a.example", topics: [topic("alerts")])])
        let cloud = doc([server("https://a.example", token: "rotated", topics: [topic("alerts")])])

        let merged = ConfigMerger.merge(base: base, local: local, cloud: cloud)
        // The v1 token only rides along for the one-time Keychain backfill…
        XCTAssertEqual(merged.servers.first?.token, "rotated")
        // …it is not a conflict dimension, and it never survives encoding.
        let encoded = try? YAMLEncoder().encode(merged)
        XCTAssertNotNil(encoded)
        XCTAssertFalse(encoded?.contains("rotated") ?? true)
        XCTAssertFalse(encoded?.contains("token") ?? true)
    }
}
