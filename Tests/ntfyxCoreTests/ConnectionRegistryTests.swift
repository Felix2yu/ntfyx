import XCTest
@testable import NtfyxCore

/// The connection table drives the menu-bar status row and the settings screen's server
/// rows; these tests pin the three-state derivation and the incremental-reload semantics
/// (untouched servers must not blink back to "connecting").
@MainActor
final class ConnectionRegistryTests: XCTestCase {

    private func makeRegistry(
        servers: [(url: String, topics: [String])] = [("https://a.example", ["t1"])]
    ) -> ConnectionRegistry {
        let registry = ConnectionRegistry()
        registry.updateServers(servers: servers)
        return registry
    }

    // MARK: - State derivation

    func testFreshServerIsConnecting() {
        let registry = makeRegistry()
        XCTAssertEqual(registry.statuses["https://a.example"]?.state, .connecting)
        XCTAssertEqual(registry.statusLine.dot, .orangePulse)
        XCTAssertEqual(registry.statusLine.text, "连接中…")
    }

    func testSuccessfulConnectionIsConnected() {
        let registry = makeRegistry()
        registry.setServerConnected("https://a.example", connected: true)
        XCTAssertEqual(registry.statuses["https://a.example"]?.state, .connected)
        XCTAssertEqual(registry.statusLine.dot, .green)
    }

    func testLostConnectionAfterSuccessIsDisconnected() {
        let registry = makeRegistry()
        registry.setServerConnected("https://a.example", connected: true)
        registry.setServerConnected("https://a.example", connected: false)
        XCTAssertEqual(registry.statuses["https://a.example"]?.state, .disconnected)
        XCTAssertEqual(registry.statusLine.dot, .red)
        XCTAssertTrue(registry.hasDisconnectedServers)
    }

    func testFailedAttemptWithoutPriorSuccessIsDisconnected() {
        let registry = makeRegistry()
        registry.setServerConnected("https://a.example", connected: false)
        XCTAssertEqual(registry.statuses["https://a.example"]?.state, .disconnected)
    }

    func testAllConnectedStatusLineCountsServersAndTopics() {
        let registry = makeRegistry(servers: [
            ("https://a.example", ["t1", "t2"]),
            ("https://b.example", ["t3"])
        ])
        registry.setServerConnected("https://a.example", connected: true)
        registry.setServerConnected("https://b.example", connected: true)
        XCTAssertEqual(registry.statusLine.text, "2 台服务器 · 3 个主题")
    }

    func testUnknownServerEventsAreIgnored() {
        let registry = makeRegistry()
        registry.setServerConnected("https://ghost.example", connected: true)
        XCTAssertNil(registry.statuses["https://ghost.example"])
    }

    // MARK: - Incremental reload

    func testUpdateServersKeepsStateOfUntouchedServers() {
        let registry = makeRegistry(servers: [("https://a.example", ["t1"])])
        registry.setServerConnected("https://a.example", connected: true)

        // Same server with a changed topic list must stay connected (no "connecting" blink).
        registry.updateServers(servers: [("https://a.example", ["t1", "t2"])])
        XCTAssertEqual(registry.statuses["https://a.example"]?.state, .connected)
        XCTAssertEqual(registry.statuses["https://a.example"]?.topics, ["t1", "t2"])
    }

    func testUpdateServersResetsOnlyNewServersToConnecting() {
        let registry = makeRegistry(servers: [("https://a.example", ["t1"])])
        registry.setServerConnected("https://a.example", connected: true)

        registry.updateServers(servers: [
            ("https://a.example", ["t1"]),
            ("https://b.example", ["t2"])
        ])
        XCTAssertEqual(registry.statuses["https://a.example"]?.state, .connected)
        XCTAssertEqual(registry.statuses["https://b.example"]?.state, .connecting)
        // Mixed state line.
        XCTAssertEqual(registry.statusLine.dot, .orangePulse)
    }

    func testRemovedServersDisappear() {
        let registry = makeRegistry(servers: [
            ("https://a.example", ["t1"]),
            ("https://b.example", ["t2"])
        ])
        registry.updateServers(servers: [("https://a.example", ["t1"])])
        XCTAssertNil(registry.statuses["https://b.example"])
        XCTAssertNotNil(registry.statuses["https://a.example"])
    }

    func testEmptyConfigShowsNoServersRow() {
        let registry = makeRegistry(servers: [])
        XCTAssertEqual(registry.statusLine.dot, .none)
        XCTAssertEqual(registry.statusLine.text, "未配置服务器")
    }

    // MARK: - Unread count / config issue

    func testSetUnreadCountDeduplicatesSameValue() {
        let registry = makeRegistry()
        XCTAssertEqual(registry.unreadCount, 0)
        registry.setUnreadCount(3)
        XCTAssertEqual(registry.unreadCount, 3)
        registry.setUnreadCount(3)
        XCTAssertEqual(registry.unreadCount, 3)
        registry.setUnreadCount(0)
        XCTAssertEqual(registry.unreadCount, 0)
    }

    func testConfigIssueLifecycle() {
        let registry = makeRegistry()
        XCTAssertNil(registry.configIssue)
        registry.showConfigWarning("w")
        XCTAssertEqual(registry.configIssue, .warning("w"))
        registry.showConfigError("e")
        XCTAssertEqual(registry.configIssue, .error("e"))
        registry.clearConfigIssue()
        XCTAssertNil(registry.configIssue)
    }
}
