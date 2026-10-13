import XCTest
@testable import NtfyxCore

/// Audit 2.2: a config reload reconciles live connections by spec, so only servers
/// whose connection-relevant settings changed reconnect. These tests pin down what
/// counts as "connection-relevant".
final class ClientSpecTests: XCTestCase {

    private func specs(_ config: AppConfig, token: String? = nil) -> Set<ClientSpec> {
        Set(Ntfyx.clientSpecs(for: config, authToken: { _ in token }))
    }

    func testTopicsAreGroupedByFetchMissed() {
        let server = ServerConfig(
            url: "https://a.example",
            topics: [
                TopicConfig(name: "alerts"),
                TopicConfig(name: "quiet", fetchMissed: false),
                TopicConfig(name: "deploy"),
            ],
            fetchMissed: true
        )
        let result = specs(AppConfig(servers: [server]))
        XCTAssertEqual(result, [
            ClientSpec(serverURL: "https://a.example", fetchMissed: true, topics: ["alerts", "deploy"], authToken: nil),
            ClientSpec(serverURL: "https://a.example", fetchMissed: false, topics: ["quiet"], authToken: nil),
        ])
    }

    func testDisplayOnlyTopicChangesDoNotAlterSpecs() {
        let before = AppConfig(servers: [ServerConfig(url: "https://a.example", topics: [
            TopicConfig(name: "alerts", silent: false),
            TopicConfig(name: "deploy", iconSymbol: "bell"),
        ])])
        let after = AppConfig(servers: [ServerConfig(url: "https://a.example", topics: [
            TopicConfig(name: "alerts", silent: true),
            TopicConfig(name: "deploy", iconSymbol: "hammer"),
        ])])
        XCTAssertEqual(specs(before), specs(after), "silent/icon changes must not force a reconnect")
    }

    func testTopicOrderDoesNotAlterSpecs() {
        let a = AppConfig(servers: [ServerConfig(url: "https://a.example", topics: [
            TopicConfig(name: "zulu"), TopicConfig(name: "alpha"),
        ])])
        let b = AppConfig(servers: [ServerConfig(url: "https://a.example", topics: [
            TopicConfig(name: "alpha"), TopicConfig(name: "zulu"),
        ])])
        XCTAssertEqual(specs(a), specs(b))
    }

    func testAddingTopicChangesOnlyThatServersSpec() {
        let shared = ClientSpec(serverURL: "https://a.example", fetchMissed: false, topics: ["alerts"], authToken: nil)
        let before = specs(AppConfig(servers: [
            ServerConfig(url: "https://a.example", topics: [TopicConfig(name: "alerts")]),
            ServerConfig(url: "https://b.example", topics: [TopicConfig(name: "keep")]),
        ]))
        let after = specs(AppConfig(servers: [
            ServerConfig(url: "https://a.example", topics: [TopicConfig(name: "alerts"), TopicConfig(name: "extra")]),
            ServerConfig(url: "https://b.example", topics: [TopicConfig(name: "keep")]),
        ]))
        let untouched = ClientSpec(serverURL: "https://b.example", fetchMissed: false, topics: ["keep"], authToken: nil)
        XCTAssertTrue(before.contains(shared))
        XCTAssertFalse(after.contains(shared), "server a's spec must change when a topic is added")
        XCTAssertTrue(after.contains(untouched) && before.contains(untouched), "server b must keep its connection")
    }

    func testTokenChangeAltersSpec() {
        let config = AppConfig(servers: [ServerConfig(url: "https://a.example", topics: [TopicConfig(name: "alerts")])])
        let old = Set(Ntfyx.clientSpecs(for: config, authToken: { _ in "tk_old" }))
        let new = Set(Ntfyx.clientSpecs(for: config, authToken: { _ in "tk_new" }))
        XCTAssertNotEqual(old, new)
    }

    func testServerWithoutTopicsProducesNoSpecs() {
        let config = AppConfig(servers: [ServerConfig(url: "https://a.example", topics: [])])
        XCTAssertTrue(specs(config).isEmpty)
    }

    // MARK: - Audit 2.6: aggregate connectivity across the fetch_missed split

    private let missed = ClientSpec(serverURL: "https://a.example", fetchMissed: true, topics: ["alerts"], authToken: nil)
    private let live = ClientSpec(serverURL: "https://a.example", fetchMissed: false, topics: ["quiet"], authToken: nil)
    private let other = ClientSpec(serverURL: "https://b.example", fetchMissed: false, topics: ["keep"], authToken: nil)

    func testSplitServerCountsConnectedOnlyWhenEveryConnectionIsUp() {
        let all: Set<ClientSpec> = [missed, live, other]
        XCTAssertFalse(
            Ntfyx.serverConnected(serverURL: "https://a.example", allSpecs: all, connectedSpecs: [missed]),
            "one of the two a.example connections is down"
        )
        XCTAssertTrue(
            Ntfyx.serverConnected(serverURL: "https://a.example", allSpecs: all, connectedSpecs: [missed, live])
        )
    }

    func testAggregatesStayIndependentPerServer() {
        let all: Set<ClientSpec> = [missed, live, other]
        XCTAssertTrue(
            Ntfyx.serverConnected(serverURL: "https://b.example", allSpecs: all, connectedSpecs: [other]),
            "a.example dropping must not flip b.example's state"
        )
        XCTAssertFalse(
            Ntfyx.serverConnected(serverURL: "https://b.example", allSpecs: all, connectedSpecs: [missed, live])
        )
    }

    func testUnknownServerNeverReportsConnected() {
        XCTAssertFalse(Ntfyx.serverConnected(serverURL: "https://c.example", allSpecs: [other], connectedSpecs: [other]))
        XCTAssertFalse(Ntfyx.serverConnected(serverURL: "https://c.example", allSpecs: [], connectedSpecs: []))
    }
}
