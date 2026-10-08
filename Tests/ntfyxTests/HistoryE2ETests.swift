import XCTest
@testable import ntfyx

/// End-to-end tests for the history pipeline: publish → poll (`since`) → on-disk SQLite store →
/// read/delete operations, served by `FakeNtfyServer`'s cache table.
///
/// These ran against the deployed fork server until that stopped being viable: it retains every
/// message forever, and a topic stays in `GET /v1/topics` as long as any of its rows survive —
/// and a cleanup that deletes messages one by one *adds* rows. Every run left a permanent trail
/// of test topics on the server.
final class HistoryE2ETests: XCTestCase {

    private static let serverURL = FakeNtfyServer.baseURL

    private var server: FakeNtfyServer!
    private var session: URLSession!
    private var databases: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = FakeNtfyServer()
        session = server.install()
    }

    override func tearDown() {
        server?.uninstall()
        for path in databases { try? FileManager.default.removeItem(atPath: path) }
        databases = []
        session = nil
        server = nil
        super.tearDown()
    }

    /// A device: its own store on a throwaway database.
    private func makeStore(_ name: String) throws -> MessageStore {
        let path = NSTemporaryDirectory() + "hist-e2e-\(name)-\(UUID().uuidString).db"
        databases.append(path)
        return try MessageStore(dbPath: path)
    }

    private func topicRef(_ topic: String) -> TopicRef {
        TopicRef(serverURL: Self.serverURL, topic: topic)
    }

    @MainActor
    private func publish(
        _ topic: String, title: String? = nil, body: String
    ) async throws {
        var request = URLRequest(url: URL(string: "\(Self.serverURL)/\(topic)")!)
        request.httpMethod = "POST"
        if let title {
            request.setValue(title, forHTTPHeaderField: "Title")
        }
        request.httpBody = body.data(using: .utf8)
        let (_, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "publish failed")
    }

    @MainActor
    func testPollStoreReadDeletePipeline() async throws {
        let topic = "alerts"
        let store = try makeStore("pipeline")

        // 1. Publish three messages
        try await publish(topic, title: "First", body: "one")
        try await publish(topic, title: "Second", body: "two")
        try await publish(topic, title: "Third", body: "three")

        // 2. Full poll into the store
        let sync = HistorySyncService(store: store)
        await sync.syncFull(topicRef(topic))

        let stored = try await store.messages(serverURL: Self.serverURL, topic: topic)
        XCTAssertEqual(stored.count, 3, "expected 3 polled messages, got \(stored.count)")
        XCTAssertEqual(stored.first?.message.title, "Third", "messages should be ordered newest first")

        // Sync state advanced to the newest message
        let syncInfo = try await store.latestSyncedInfo(serverURL: Self.serverURL, topic: topic)
        XCTAssertNotNil(syncInfo?.id)

        // 3. Publish one more and do an incremental sync — only the new one arrives
        try await publish(topic, title: "Fourth", body: "four")
        await sync.syncIncremental(topicRef(topic))

        let afterIncremental = try await store.messages(serverURL: Self.serverURL, topic: topic)
        XCTAssertEqual(afterIncremental.count, 4, "incremental sync should only add the new message")
        XCTAssertEqual(afterIncremental.first?.message.title, "Fourth")

        // 4. Mark all read → unread count empty
        try await store.markAllRead(serverURL: Self.serverURL, topic: topic)
        let unread = try await store.unreadCountsByTopic()
        XCTAssertNil(unread[topicRef(topic)])

        // 5. Mark one unread again, delete it locally + on server
        let target = afterIncremental[0]
        try await store.markRead(false, serverURL: Self.serverURL, topic: topic, messageID: target.message.id)

        let deleted = try await store.tombstoneMessage(
            serverURL: Self.serverURL, topic: topic, messageID: target.message.id
        )
        XCTAssertTrue(deleted)
        await MessageActionService.deleteOnServer(
            serverURL: Self.serverURL, topic: topic,
            sequenceID: target.message.sequenceId, messageID: target.message.id,
            authToken: nil, session: session
        )

        let remaining = try await store.messages(serverURL: Self.serverURL, topic: topic)
        XCTAssertEqual(remaining.count, 3)
        XCTAssertFalse(remaining.contains { $0.message.id == target.message.id })

        // 6. Poll replay must not resurrect the deleted message. The server keeps both the
        // message row and its delete event, so only the tombstone can hold it down.
        await sync.syncFull(topicRef(topic))
        let afterReplay = try await store.messages(serverURL: Self.serverURL, topic: topic)
        XCTAssertFalse(afterReplay.contains { $0.message.id == target.message.id },
                       "tombstoned message must survive a full poll replay")
        XCTAssertEqual(server.rows(topic: topic).filter { $0.event == "message" }.count, 4,
                       "a server-side delete leaves the message cached")
    }

    /// A server-side `message_clear` must be applied as *read*, never as a delete, and a
    /// device that has never seen the topic must inherit the read state on its first full
    /// sync — the poll replays the event after its target message (ascending order).
    @MainActor
    func testServerMarkReadReplaysAsReadNotDelete() async throws {
        let topic = "reads"
        let ref = topicRef(topic)

        try await publish(topic, title: "Alpha", body: "alpha")
        try await publish(topic, title: "Beta", body: "beta")

        // Device A: sync, then mark one message read locally + on the server.
        let storeA = try makeStore("A")
        await HistorySyncService(store: storeA).syncFull(ref)
        let onA = try await storeA.messages(serverURL: Self.serverURL, topic: topic)
        XCTAssertEqual(onA.count, 2, "both published messages should be polled")

        let target = onA.first { $0.message.title == "Alpha" } ?? onA[0]
        try await storeA.markRead(true, serverURL: Self.serverURL, topic: topic, messageID: target.message.id)
        let accepted = await MessageActionService.markReadOnServer(
            serverURL: Self.serverURL, topic: topic,
            sequenceID: target.message.sequenceId, messageID: target.message.id,
            authToken: nil, session: session
        )
        XCTAssertTrue(accepted, "server should accept GET /<topic>/<id>/read")

        // Device B: fresh store, first-ever sync.
        let storeB = try makeStore("B")
        await HistorySyncService(store: storeB).syncFull(ref)
        let onB = try await storeB.messages(serverURL: Self.serverURL, topic: topic)
        XCTAssertEqual(onB.count, 2, "message_clear must mark read, not delete")
        XCTAssertEqual(onB.first { $0.message.id == target.message.id }?.isRead, true,
                       "read state must come from the replayed message_clear event")
        XCTAssertEqual(onB.filter { $0.isRead }.count, 1)
        XCTAssertEqual(onB.filter { !$0.isRead }.count, 1)
    }

    /// The batched `/read` route is a fork extension: one request for a comma-separated id
    /// list, and every device converges from the resulting events.
    @MainActor
    func testBatchedServerMarkReadConvergesOnSecondDevice() async throws {
        let topic = "batched"
        let ref = topicRef(topic)
        for i in 0..<3 {
            try await publish(topic, title: "N\(i)", body: "body\(i)")
        }

        let storeA = try makeStore("batch-A")
        await HistorySyncService(store: storeA).syncFull(ref)

        let onA = try await storeA.messages(serverURL: Self.serverURL, topic: topic)
        XCTAssertEqual(onA.count, 3)

        let synced = await MessageActionService.markAllReadOnServer(
            serverURL: Self.serverURL, topic: topic,
            targets: onA.map { ($0.message.sequenceId, $0.message.id) },
            authToken: nil, session: session
        )
        XCTAssertEqual(synced, 3, "server should accept one /<topic>/<ids>/read request")

        let storeB = try makeStore("batch-B")
        await HistorySyncService(store: storeB).syncFull(ref)

        let onB = try await storeB.messages(serverURL: Self.serverURL, topic: topic)
        XCTAssertEqual(onB.count, 3, "clear events must not delete the messages")
        XCTAssertTrue(onB.allSatisfy(\.isRead), "every replayed clear event should mark its message read")
    }

    /// `/v1/topics` is what the subscribe sheet is built on: it lists every topic with a cached
    /// row. That includes a topic whose messages were all deleted — the delete events are rows
    /// too — which is exactly why a test run must not leave them behind on a real server.
    @MainActor
    func testServerTopicListingKeepsTopicUntilRetired() async throws {
        let topic = "discovery"
        let ref = topicRef(topic)
        try await publish(topic, body: "discovery")
        try await publish(topic, body: "second")

        var topics = try await MessageActionService.fetchServerTopics(
            serverURL: Self.serverURL, authToken: nil, session: session
        )
        XCTAssertTrue(
            topics.contains(topic),
            "/v1/topics should list \(topic); got \(topics)"
        )

        let store = try makeStore("discovery")
        await HistorySyncService(store: store).syncFull(ref)
        let messages = try await store.messages(serverURL: Self.serverURL, topic: topic)
        await MessageActionService.deleteAllOnServer(
            serverURL: Self.serverURL, topic: topic,
            targets: messages.map { ($0.message.sequenceId, $0.message.id) },
            authToken: nil, session: session
        )

        topics = try await MessageActionService.fetchServerTopics(
            serverURL: Self.serverURL, authToken: nil, session: session
        )
        XCTAssertTrue(
            topics.contains(topic),
            "deleting every message leaves delete events behind, so the topic is still listed"
        )

        // Retiring purges the whole cache entry, listing included.
        let purged = try await MessageActionService.retireTopic(
            serverURL: Self.serverURL, topic: topic, authToken: nil, session: session
        )
        XCTAssertEqual(purged, 4, "both messages and both delete events are purged")
        topics = try await MessageActionService.fetchServerTopics(
            serverURL: Self.serverURL, authToken: nil, session: session
        )
        XCTAssertFalse(topics.contains(topic))
    }

    /// Retiring a topic is a single request that purges the whole server cache, which is what
    /// makes the messages vanish on every other device at once.
    @MainActor
    func testRetireTopicPurgesServerCacheForOtherDevices() async throws {
        let topic = "retire"
        let ref = topicRef(topic)
        for i in 0..<2 {
            try await publish(topic, title: "R\(i)", body: "body\(i)")
        }

        let store = try makeStore("retire")
        await HistorySyncService(store: store).syncFull(ref)
        let cached = try await store.messages(serverURL: Self.serverURL, topic: topic)
        XCTAssertEqual(cached.count, 2)

        let deleted = try await MessageActionService.retireTopic(
            serverURL: Self.serverURL, topic: topic, authToken: nil, session: session
        )
        XCTAssertEqual(deleted, 2)

        // A brand new device must now see nothing at all.
        let storeB = try makeStore("retire-B")
        await HistorySyncService(store: storeB).syncFull(ref)
        let onB = try await storeB.messages(serverURL: Self.serverURL, topic: topic)
        XCTAssertTrue(onB.isEmpty, "retired topic should leave no cached messages, got \(onB.count)")
    }
}
