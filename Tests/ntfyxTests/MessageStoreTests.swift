import XCTest
@testable import ntfyx

final class MessageStoreTests: XCTestCase {
    private var store: MessageStore!

    override func setUpWithError() throws {
        store = try MessageStore.inMemory()
    }

    override func tearDownWithError() throws {
        store = nil
    }

    // MARK: - Helpers

    /// Total unread across topics, read through the same aggregate the app uses.
    private func totalUnread() async throws -> Int {
        try await store.unreadCountsByTopic().values.reduce(0, +)
    }

    private func makeMessage(
        id: String = "abc123",
        topic: String = "alerts",
        time: Int = 1_700_000_000,
        title: String? = "Test title",
        message: String? = "Test body",
        priority: Int? = 3,
        tags: [String]? = ["warning"],
        sequenceId: String? = nil,
        event: String = "message"
    ) -> NtfyMessage {
        NtfyMessage(
            id: id,
            time: time,
            event: event,
            topic: topic,
            message: message,
            title: title,
            priority: priority,
            tags: tags,
            click: nil,
            actions: nil,
            attachment: nil,
            contentType: nil,
            sequenceId: sequenceId
        )
    }

    // MARK: - Upsert

    func testUpsertAndFetch() async throws {
        try await store.upsert(makeMessage(), serverURL: "https://ntfy.example.com")

        let messages = try await store.messages(serverURL: "https://ntfy.example.com", topic: "alerts")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].message.id, "abc123")
        XCTAssertEqual(messages[0].message.title, "Test title")
        XCTAssertEqual(messages[0].message.priority, 3)
        XCTAssertEqual(messages[0].message.tags, ["warning"])
        XCTAssertFalse(messages[0].isRead)
        XCTAssertFalse(messages[0].isDeleted)
    }

    func testUpsertIsIdempotent() async throws {
        let message = makeMessage()
        try await store.upsert(message, serverURL: "https://ntfy.example.com")
        try await store.upsert(message, serverURL: "https://ntfy.example.com")

        let messages = try await store.messages(serverURL: "https://ntfy.example.com", topic: "alerts")
        XCTAssertEqual(messages.count, 1)
    }

    func testUpsertDoesNotOverwriteReadState() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.markRead(true, serverURL: "https://s.example", topic: "alerts", messageID: "m1")

        // Poll replay of the same message must not reset read state
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")

        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertTrue(messages[0].isRead)
    }

    func testUpsertDoesNotResurrectDeletedMessage() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.tombstoneMessage(serverURL: "https://s.example", topic: "alerts", messageID: "m1")

        // Poll replay after local delete must not bring the message back
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")

        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertTrue(messages.isEmpty)
    }

    // MARK: - Ordering & Pagination

    func testMessagesOrderedNewestFirst() async throws {
        for (index, time) in [100, 300, 200].enumerated() {
            try await store.upsert(makeMessage(id: "m\(index)", time: time), serverURL: "https://s.example")
        }

        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(messages.map { $0.message.time }, [300, 200, 100])
    }

    func testPaginationWithBeforeTimeCursor() async throws {
        for index in 0..<10 {
            try await store.upsert(makeMessage(id: "m\(index)", time: 1_000 + index), serverURL: "https://s.example")
        }

        let firstPage = try await store.messages(serverURL: "https://s.example", topic: "alerts", limit: 4)
        XCTAssertEqual(firstPage.map { $0.message.time }, [1009, 1008, 1007, 1006])

        let secondPage = try await store.messages(
            serverURL: "https://s.example", topic: "alerts", limit: 4,
            before: firstPage.last?.cursor
        )
        XCTAssertEqual(secondPage.map { $0.message.time }, [1005, 1004, 1003, 1002])
    }

    // audit 2.3: a page boundary landing inside a same-second burst must not skip rows.
    func testPaginationKeepsSameSecondMessagesAcrossPages() async throws {
        let t = 1_700_000_500
        for index in 0..<5 {
            try await store.upsert(makeMessage(id: "m\(index)", time: t), serverURL: "https://s.example")
        }

        var collected: [String] = []
        var cursor: PageCursor?
        while true {
            let page = try await store.messages(
                serverURL: "https://s.example", topic: "alerts", limit: 2, before: cursor
            )
            collected.append(contentsOf: page.map { $0.message.id })
            guard page.count == 2, let last = page.last else { break }
            cursor = last.cursor
        }
        XCTAssertEqual(Set(collected), Set(["m0", "m1", "m2", "m3", "m4"]))
        XCTAssertEqual(collected.count, 5)  // no duplicates, no drops
    }

    func testMessageCount() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m2"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m3", topic: "other"), serverURL: "https://s.example")
        try await store.tombstoneMessage(serverURL: "https://s.example", topic: "alerts", messageID: "m2")

        let alertsCount = try await store.messageCount(serverURL: "https://s.example", topic: "alerts")
        let otherCount = try await store.messageCount(serverURL: "https://s.example", topic: "other")
        XCTAssertEqual(alertsCount, 1)
        XCTAssertEqual(otherCount, 1)
    }

    // MARK: - Read state

    func testMarkReadAndUnread() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")

        try await store.markRead(true, serverURL: "https://s.example", topic: "alerts", messageID: "m1")
        var messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertTrue(messages[0].isRead)

        try await store.markRead(false, serverURL: "https://s.example", topic: "alerts", messageID: "m1")
        messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertFalse(messages[0].isRead)
    }

    func testMarkAllRead() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m2"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m3", topic: "other"), serverURL: "https://s.example")

        try await store.markAllRead(serverURL: "https://s.example", topic: "alerts")

        let alerts = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertTrue(alerts.allSatisfy { $0.isRead })

        // Other topic untouched
        let others = try await store.messages(serverURL: "https://s.example", topic: "other")
        XCTAssertFalse(others[0].isRead)
    }

    // MARK: - Read watermark

    /// Replays the way `applyBatch` does it: the row comes from the server's cache, so the
    /// watermark applies to it.
    private func backfill(
        _ message: NtfyMessage, serverURL: String
    ) async throws {
        try await store.upsert(message, serverURL: serverURL, asBackfill: true)
    }

    /// The unread backlash after adding a subscription: retention drops the read rows
    /// `markAllRead` just touched, the next `since=all` replay re-inserts them, and without
    /// the watermark they come back unread — refilling the badge with read messages.
    func testReplayAfterRetentionLandsReadBelowWatermark() async throws {
        try await store.upsert(makeMessage(id: "old", time: 1_000), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "new", time: 2_000), serverURL: "https://s.example")
        try await store.markAllRead(serverURL: "https://s.example", topic: "alerts")

        let pruned = try await store.enforceRetention(
            MessageStore.RetentionPolicy(tombstoneGraceDays: 0, readRetentionDays: 0, maxReadRowsPerTopic: 1)
        )
        XCTAssertEqual(pruned, 1)

        try await backfill(makeMessage(id: "old", time: 1_000), serverURL: "https://s.example")

        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.allSatisfy { $0.isRead })
        let unread = try await totalUnread()
        XCTAssertEqual(unread, 0)
    }

    /// The watermark covers what was read, not everything the replay carries: a message newer
    /// than the newest row at mark time still counts.
    func testBackfillNewerThanWatermarkStaysUnread() async throws {
        try await store.upsert(makeMessage(id: "m1", time: 1_000), serverURL: "https://s.example")
        try await store.markAllRead(serverURL: "https://s.example", topic: "alerts")

        try await backfill(makeMessage(id: "m2", time: 2_000), serverURL: "https://s.example")

        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(messages.first { $0.message.id == "m2" }?.isRead, false)
        let unread = try await totalUnread()
        XCTAssertEqual(unread, 1)
    }

    /// Marking a topic unread is the user asking for those messages again, so the record goes
    /// away and a replay of the same message counts as unread.
    func testMarkAllUnreadClearsWatermark() async throws {
        try await store.upsert(makeMessage(id: "m1", time: 1_000), serverURL: "https://s.example")
        try await store.markAllRead(serverURL: "https://s.example", topic: "alerts")

        // Physically remove the row, so the re-insert is not the idempotent `INSERT OR IGNORE`
        // that would keep the existing read flag. Tombstone rules need a grace period above
        // zero (0 disables the rule), so the cutoff is pushed past the tombstone's timestamp.
        try await store.tombstoneMessage(serverURL: "https://s.example", topic: "alerts", messageID: "m1")
        let pruned = try await store.enforceRetention(
            MessageStore.RetentionPolicy(tombstoneGraceDays: 1, readRetentionDays: 0, maxReadRowsPerTopic: 0),
            now: Date().addingTimeInterval(2 * 86_400)
        )
        XCTAssertEqual(pruned, 1)

        try await store.markAllRead(false, serverURL: "https://s.example", topic: "alerts")
        try await backfill(makeMessage(id: "m1", time: 1_000), serverURL: "https://s.example")

        let unread = try await totalUnread()
        XCTAssertEqual(unread, 1)
    }

    /// A deleted subscription loses its watermark together with the sync row; the cached copy
    /// has to go too, or re-adding the same topic would file the replayed messages as read.
    func testDeleteTopicDropsTheWatermark() async throws {
        try await store.upsert(makeMessage(id: "m1", time: 1_000), serverURL: "https://s.example")
        try await store.markAllRead(serverURL: "https://s.example", topic: "alerts")
        try await store.deleteTopic(serverURL: "https://s.example", topic: "alerts")

        try await backfill(makeMessage(id: "m1", time: 1_000), serverURL: "https://s.example")

        let unread = try await totalUnread()
        XCTAssertEqual(unread, 1)
    }

    /// A message published in the second the topic was cleared is new, not backfill: the
    /// watermark is for replays only, so a live delivery is never silently read.
    func testLiveMessageIgnoresTheWatermark() async throws {
        try await store.upsert(makeMessage(id: "m1", time: 1_000), serverURL: "https://s.example")
        try await store.markAllRead(serverURL: "https://s.example", topic: "alerts")

        try await store.upsert(makeMessage(id: "m2", time: 1_000), serverURL: "https://s.example")

        let unread = try await totalUnread()
        XCTAssertEqual(unread, 1)
    }

    /// An existing database keeps its old `sync_state` table, so the watermark column arrives
    /// through an ALTER and reopening has to tolerate SQLite's "duplicate column name" answer
    /// rather than fail to open.
    func testReopeningADatabaseKeepsTheWatermark() async throws {
        let path = NSTemporaryDirectory() + "ntfyx-watermark-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = try MessageStore(dbPath: path)
        try await first.upsert(makeMessage(id: "m1", time: 1_000), serverURL: "https://s.example")
        try await first.upsert(makeMessage(id: "m2", time: 2_000), serverURL: "https://s.example")
        try await first.markAllRead(serverURL: "https://s.example", topic: "alerts")

        let second = try MessageStore(dbPath: path)
        // A row the first store never saw: only the persisted watermark can make it read.
        try await second.upsert(
            makeMessage(id: "m3", time: 1_500), serverURL: "https://s.example", asBackfill: true
        )

        let unread = try await second.unreadCountsByTopic().values.reduce(0, +)
        XCTAssertEqual(unread, 0)
    }

    func testUnreadCountsByTopic() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m2"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m3", topic: "other"), serverURL: "https://s2.example")

        try await store.markRead(true, serverURL: "https://s.example", topic: "alerts", messageID: "m1")

        let counts = try await store.unreadCountsByTopic()
        XCTAssertEqual(counts[TopicRef(serverURL: "https://s.example", topic: "alerts")], 1)
        XCTAssertEqual(counts[TopicRef(serverURL: "https://s2.example", topic: "other")], 1)
    }

    func testUnreadIgnoresDeletedMessages() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.tombstoneMessage(serverURL: "https://s.example", topic: "alerts", messageID: "m1")

        let counts = try await store.unreadCountsByTopic()
        XCTAssertTrue(counts.isEmpty)
        let total = try await totalUnread()
        XCTAssertEqual(total, 0)
    }

    // MARK: - Tombstones

    func testTombstoneMessage() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")

        let affected = try await store.tombstoneMessage(serverURL: "https://s.example", topic: "alerts", messageID: "m1")
        XCTAssertTrue(affected)

        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertTrue(messages.isEmpty)
    }

    func testTombstoneAll() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m2"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m3", topic: "other"), serverURL: "https://s.example")

        try await store.tombstoneAll(serverURL: "https://s.example", topic: "alerts")

        let remaining = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        let otherCount = try await store.messageCount(serverURL: "https://s.example", topic: "other")
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(otherCount, 1)
    }

    // MARK: - Delete events

    func testApplyDeleteEventBySequenceID() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: "seq-1"), serverURL: "https://s.example")

        // Server delete events carry a fresh event id, with sequence_id pointing at the target
        let affected = try await store.applyDeleteEvent(
            serverURL: "https://s.example", topic: "alerts",
            targetSequenceID: "seq-1", targetMessageID: "evt-random"
        )
        XCTAssertTrue(affected)
        let remaining = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertTrue(remaining.isEmpty)
    }

    func testApplyDeleteEventByMessageID() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: nil), serverURL: "https://s.example")

        let affected = try await store.applyDeleteEvent(
            serverURL: "https://s.example", topic: "alerts",
            targetSequenceID: nil, targetMessageID: "m1"
        )
        XCTAssertTrue(affected)
        let remaining = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertTrue(remaining.isEmpty)
    }

    func testApplyDeleteEventNoMatch() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")

        let affected = try await store.applyDeleteEvent(
            serverURL: "https://s.example", topic: "alerts",
            targetSequenceID: "nope", targetMessageID: "also-nope"
        )
        XCTAssertFalse(affected)
        let count = try await store.messageCount(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(count, 1)
    }

    // MARK: - Action events (delete vs. clear/read)

    /// `/<topic>/<seq>/read|clear` makes the server broadcast message_clear, which means
    /// "mark as read" — never "remove the message".
    func testClearEventMarksReadAndKeepsMessage() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: "seq-1"), serverURL: "https://s.example")
        var unread = try await totalUnread()
        XCTAssertEqual(unread, 1)

        let affected = try await store.applyActionEvent(
            makeMessage(id: "evt-fresh", sequenceId: "seq-1", event: NtfyMessage.clearEvent),
            serverURL: "https://s.example"
        )
        XCTAssertTrue(affected)

        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].isRead)
        XCTAssertFalse(messages[0].isDeleted)
        unread = try await totalUnread()
        XCTAssertEqual(unread, 0)
    }

    func testDeleteEventStillTombstones() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: "seq-1"), serverURL: "https://s.example")

        let affected = try await store.applyActionEvent(
            makeMessage(id: "evt-fresh", sequenceId: "seq-1", event: NtfyMessage.deleteEvent),
            serverURL: "https://s.example"
        )
        XCTAssertTrue(affected)
        let remaining = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertTrue(remaining.isEmpty)
    }

    /// Our client puts `sequence_id ?? message_id` in the URL, so a clear event for a message
    /// that has no sequence id carries that message id as its sequence_id.
    func testClearEventMatchesMessageWithoutSequenceID() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: nil), serverURL: "https://s.example")

        let affected = try await store.applyActionEvent(
            makeMessage(id: "evt-fresh", sequenceId: "m1", event: NtfyMessage.clearEvent),
            serverURL: "https://s.example"
        )
        XCTAssertTrue(affected)

        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].isRead)
    }

    /// A `since` replay arrives as one batch: rows land, the events inside it still apply to
    /// the messages that preceded them, and the withdrawn banners come back in one list.
    func testApplyBatchStoresMessagesAndAppliesEvents() async throws {
        let revoked = try await store.applyBatch([
            makeMessage(id: "m1", sequenceId: "seq-1"),
            makeMessage(id: "m2", time: 1_700_000_001, sequenceId: "seq-2"),
            makeMessage(id: "evt", sequenceId: "seq-2", event: NtfyMessage.deleteEvent),
            makeMessage(id: "m3", time: 1_700_000_002),
        ], serverURL: "https://s.example")

        XCTAssertEqual(revoked, ["m2"])
        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(Set(messages.map { $0.message.id }), ["m1", "m3"])
    }

    /// Replaying the same batch (a reconnect before the watermark was stored) must not
    /// duplicate rows or resurrect a tombstoned message.
    func testApplyBatchIsIdempotent() async throws {
        let batch = [
            makeMessage(id: "m1", sequenceId: "seq-1"),
            makeMessage(id: "evt", sequenceId: "seq-1", event: NtfyMessage.deleteEvent),
        ]
        _ = try await store.applyBatch(batch, serverURL: "https://s.example")
        _ = try await store.applyBatch(batch, serverURL: "https://s.example")

        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertTrue(messages.isEmpty)
        let rowStillThere = try await store.rawRowExists(
            serverURL: "https://s.example", topic: "alerts", messageID: "m1"
        )
        XCTAssertTrue(rowStillThere)  // one tombstone, not a resurrected or duplicated row
    }

    func testClearEventIgnoresUnknownAndDeletedTargets() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: "seq-1"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m2", time: 1_700_000_001, sequenceId: "seq-2"), serverURL: "https://s.example")
        try await store.tombstoneMessage(serverURL: "https://s.example", topic: "alerts", messageID: "m2")

        let unknown = try await store.applyActionEvent(
            makeMessage(id: "evt", sequenceId: "nope", event: NtfyMessage.clearEvent),
            serverURL: "https://s.example"
        )
        XCTAssertFalse(unknown)

        let onTombstone = try await store.applyActionEvent(
            makeMessage(id: "evt", sequenceId: "seq-2", event: NtfyMessage.clearEvent),
            serverURL: "https://s.example"
        )
        XCTAssertFalse(onTombstone)
        let unread = try await totalUnread()
        XCTAssertEqual(unread, 1)
    }

    /// A clear event replayed by `since=` must not duplicate or resurrect anything.
    func testClearEventIsIdempotent() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: "seq-1"), serverURL: "https://s.example")
        let event = makeMessage(id: "evt", sequenceId: "seq-1", event: NtfyMessage.clearEvent)

        try await store.applyActionEvent(event, serverURL: "https://s.example")
        try await store.applyActionEvent(event, serverURL: "https://s.example")

        let messages = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].isRead)
        XCTAssertFalse(messages[0].isDeleted)
    }

    // MARK: - Action event target lookup

    /// Revoking a banner needs the id the message was delivered under, not the sequence id
    /// the event carries.
    func testTargetMessageIDResolvesFromRealSequenceID() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: "seq-1"), serverURL: "https://s.example")
        let resolved = try await store.targetMessageID(
            for: makeMessage(id: "evt", sequenceId: "seq-1", event: NtfyMessage.clearEvent),
            serverURL: "https://s.example"
        )
        XCTAssertEqual(resolved, "m1")
    }

    /// Without a sequence id the event echoes back the message id we put in the URL.
    func testTargetMessageIDResolvesFromEchoedMessageID() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: nil), serverURL: "https://s.example")
        let resolved = try await store.targetMessageID(
            for: makeMessage(id: "evt", sequenceId: "m1", event: NtfyMessage.clearEvent),
            serverURL: "https://s.example"
        )
        XCTAssertEqual(resolved, "m1")
    }

    /// A delete event still has to resolve its target after the row is tombstoned — that is
    /// precisely the moment the banner has to go.
    func testTargetMessageIDResolvesTombstonedRow() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: "seq-1"), serverURL: "https://s.example")
        try await store.applyActionEvent(
            makeMessage(id: "evt", sequenceId: "seq-1", event: NtfyMessage.deleteEvent),
            serverURL: "https://s.example"
        )
        let resolved = try await store.targetMessageID(
            for: makeMessage(id: "evt", sequenceId: "seq-1", event: NtfyMessage.deleteEvent),
            serverURL: "https://s.example"
        )
        XCTAssertEqual(resolved, "m1")
    }

    func testTargetMessageIDIgnoresUnknownAndForeignTargets() async throws {
        try await store.upsert(makeMessage(id: "m1", sequenceId: "seq-1"), serverURL: "https://s.example")

        let unknown = try await store.targetMessageID(
            for: makeMessage(id: "evt", sequenceId: "nope", event: NtfyMessage.deleteEvent),
            serverURL: "https://s.example"
        )
        XCTAssertNil(unknown)

        let otherServer = try await store.targetMessageID(
            for: makeMessage(id: "evt", sequenceId: "seq-1", event: NtfyMessage.deleteEvent),
            serverURL: "https://other.example"
        )
        XCTAssertNil(otherServer)

        let otherTopic = try await store.targetMessageID(
            for: makeMessage(id: "evt", topic: "other", sequenceId: "seq-1", event: NtfyMessage.deleteEvent),
            serverURL: "https://s.example"
        )
        XCTAssertNil(otherTopic)
    }

    // MARK: - Search

    func testSearchFilter() async throws {
        try await store.upsert(makeMessage(id: "m1", title: "Deploy failed", message: "service crashed"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m2", title: "Backup done", message: "all good"), serverURL: "https://s.example")

        let results = try await store.messages(serverURL: "https://s.example", topic: "alerts", searchText: "deploy")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].message.id, "m1")
    }

    func testSearchFilterOnlyUnread() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m2"), serverURL: "https://s.example")
        try await store.markRead(true, serverURL: "https://s.example", topic: "alerts", messageID: "m1")

        let unread = try await store.messages(serverURL: "https://s.example", topic: "alerts", onlyUnread: true)
        XCTAssertEqual(unread.map { $0.message.id }, ["m2"])
    }

    // MARK: - Sync state

    func testSyncStateRoundtrip() async throws {
        var info = try await store.latestSyncedInfo(serverURL: "https://s.example", topic: "alerts")
        XCTAssertNil(info)

        try await store.setSyncedInfo(serverURL: "https://s.example", topic: "alerts", id: "abc", time: 1_234)
        info = try await store.latestSyncedInfo(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(info?.id, "abc")
        XCTAssertEqual(info?.time, 1_234)

        // Upsert overwrites
        try await store.setSyncedInfo(serverURL: "https://s.example", topic: "alerts", id: "def", time: 5_678)
        info = try await store.latestSyncedInfo(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(info?.id, "def")
        XCTAssertEqual(info?.time, 5_678)
    }

    // MARK: - Isolation between servers

    func testServerIsolation() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://a.example")
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://b.example")

        // Same msg_id on different servers are distinct rows
        let aCount = try await store.messageCount(serverURL: "https://a.example", topic: "alerts")
        let bCount = try await store.messageCount(serverURL: "https://b.example", topic: "alerts")
        XCTAssertEqual(aCount, 1)
        XCTAssertEqual(bCount, 1)
    }

    // MARK: - Orphan cleanup after subscription deletion (audit 1.4)

    func testDeleteTopicRemovesMessagesAndSyncState() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://a.example")
        try await store.upsert(makeMessage(id: "m2", topic: "keep"), serverURL: "https://a.example")
        try await store.setSyncedInfo(serverURL: "https://a.example", topic: "alerts", id: "m1", time: 1_700_000_000)

        try await store.deleteTopic(serverURL: "https://a.example", topic: "alerts")

        let alertsCount = try await store.messageCount(serverURL: "https://a.example", topic: "alerts")
        let unreadTotal = try await totalUnread()
        XCTAssertEqual(alertsCount, 0)
        XCTAssertEqual(unreadTotal, 1)  // only the kept topic counts now
        let info = try await store.latestSyncedInfo(serverURL: "https://a.example", topic: "alerts")
        XCTAssertNil(info?.id)
        // Other topics on the same server are untouched.
        let keepCount = try await store.messageCount(serverURL: "https://a.example", topic: "keep")
        XCTAssertEqual(keepCount, 1)
    }

    func testTrackedTopicsListsStoredPairs() async throws {
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://a.example")
        try await store.upsert(makeMessage(id: "m2", topic: "deploy"), serverURL: "https://b.example")
        let tracked = try await store.trackedTopics()
        XCTAssertEqual(tracked, [
            TopicRef(serverURL: "https://a.example", topic: "alerts"),
            TopicRef(serverURL: "https://b.example", topic: "deploy"),
        ])
    }

    // MARK: - Global search (audit 3.4)

    func testSearchAllMatchesAcrossServersTopicsAndFields() async throws {
        try await store.upsert(makeMessage(id: "m1", topic: "alerts", title: "磁盘告警", message: "server disk full"), serverURL: "https://a.example")
        try await store.upsert(makeMessage(id: "m2", topic: "deploy", time: 1_700_000_050, title: "OK", message: "restart nginx"), serverURL: "https://b.example")
        try await store.upsert(makeMessage(id: "m3", topic: "disk-usage", time: 1_700_000_060, title: "nothing", message: "nothing"), serverURL: "https://b.example")

        let byBody = try await store.searchAll(query: "disk")
        XCTAssertEqual(Set(byBody.map { $0.message.id }), ["m1", "m3"])
        // server_url/topic come from the row, not from a caller-supplied value.
        XCTAssertEqual(byBody.first(where: { $0.message.id == "m1" })?.serverURL, "https://a.example")
        XCTAssertEqual(byBody.first(where: { $0.message.id == "m3" })?.topicRef, TopicRef(serverURL: "https://b.example", topic: "disk-usage"))

        let byTitle = try await store.searchAll(query: "告警")
        XCTAssertEqual(byTitle.map { $0.message.id }, ["m1"])

        let byTopicName = try await store.searchAll(query: "deploy")
        XCTAssertEqual(byTopicName.map { $0.message.id }, ["m2"])
    }

    func testSearchAllNewestFirstExcludesDeletedHonorsCursorAndLimit() async throws {
        for i in 0..<5 {
            try await store.upsert(makeMessage(id: "m\(i)", time: 1_700_000_000 + i, message: "hit \(i)"), serverURL: "https://a.example")
        }
        try await store.upsert(makeMessage(id: "gone", time: 1_700_000_100, message: "hit gone"), serverURL: "https://a.example")
        try await store.tombstoneMessage(serverURL: "https://a.example", topic: "alerts", messageID: "gone")

        let all = try await store.searchAll(query: "hit")
        XCTAssertEqual(all.map { $0.message.id }, ["m4", "m3", "m2", "m1", "m0"])  // newest first, tombstone excluded

        let older = try await store.searchAll(query: "hit", before: all[2].cursor)  // older than m2
        XCTAssertEqual(older.map { $0.message.id }, ["m1", "m0"])

        let limited = try await store.searchAll(query: "hit", limit: 2)
        XCTAssertEqual(limited.map { $0.message.id }, ["m4", "m3"])
    }

    func testSearchAllEscapesLikeWildcards() async throws {
        try await store.upsert(makeMessage(id: "pct", title: "note", message: "100% done"), serverURL: "https://a.example")
        try await store.upsert(makeMessage(id: "und", title: "note", message: "100x done"), serverURL: "https://a.example")

        let hits = try await store.searchAll(query: "100%")
        XCTAssertEqual(hits.map { $0.message.id }, ["pct"])
    }

    // MARK: - Retention (audit 2.4)

    private func testNow() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }

    func testRetentionRemovesOldReadButKeepsUnreadAndRecent() async throws {
        let now = 1_700_000_000
        let day = 86_400
        try await store.upsert(makeMessage(id: "oldRead", time: now - 100 * day), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "oldUnread", time: now - 100 * day), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "freshRead", time: now - day), serverURL: "https://s.example")
        try await store.markRead(true, serverURL: "https://s.example", topic: "alerts", messageID: "oldRead")
        try await store.markRead(true, serverURL: "https://s.example", topic: "alerts", messageID: "freshRead")

        let policy = MessageStore.RetentionPolicy(tombstoneGraceDays: 0, readRetentionDays: 90, maxReadRowsPerTopic: 0)
        let deleted = try await store.enforceRetention(policy, now: testNow())
        XCTAssertEqual(deleted, 1)

        let remaining = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(Set(remaining.map { $0.message.id }), ["oldUnread", "freshRead"])
    }

    func testRetentionPhysicallyRemovesExpiredTombstonesWithinGrace() async throws {
        try await store.upsert(makeMessage(id: "gone", time: 1_000), serverURL: "https://s.example")
        try await store.tombstoneMessage(serverURL: "https://s.example", topic: "alerts", messageID: "gone")
        let realNow = Date().timeIntervalSince1970
        let policy = MessageStore.RetentionPolicy(tombstoneGraceDays: 30, readRetentionDays: 0, maxReadRowsPerTopic: 0)

        // deleted_at was just stamped → still within the 30-day grace.
        let within = try await store.enforceRetention(policy, now: Date(timeIntervalSince1970: realNow + 10 * 86_400.0))
        XCTAssertEqual(within, 0)
        let kept = try await store.rawRowExists(serverURL: "https://s.example", topic: "alerts", messageID: "gone")
        XCTAssertTrue(kept)  // tombstone survives, so a poll replay cannot resurrect the message

        // 31 days later the grace has lapsed.
        let expired = try await store.enforceRetention(policy, now: Date(timeIntervalSince1970: realNow + 31 * 86_400.0))
        XCTAssertEqual(expired, 1)
        let removed = try await store.rawRowExists(serverURL: "https://s.example", topic: "alerts", messageID: "gone")
        XCTAssertFalse(removed)
    }

    func testRetentionCapsReadRowsPerTopicAndNeverUnread() async throws {
        let day = 86_400
        for index in 1...5 {
            try await store.upsert(makeMessage(id: "r\(index)", time: index * day), serverURL: "https://s.example")
            try await store.markRead(true, serverURL: "https://s.example", topic: "alerts", messageID: "r\(index)")
        }
        try await store.upsert(makeMessage(id: "u1", time: day), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "u2", time: 2 * day), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "other", topic: "other", time: day), serverURL: "https://s.example")
        try await store.markRead(true, serverURL: "https://s.example", topic: "other", messageID: "other")

        let policy = MessageStore.RetentionPolicy(tombstoneGraceDays: 0, readRetentionDays: 0, maxReadRowsPerTopic: 3)
        let deleted = try await store.enforceRetention(policy, now: Date(timeIntervalSince1970: Double(10 * day)))
        XCTAssertEqual(deleted, 2)  // r1, r2 fall outside the newest-3 window; unread do not

        let remaining = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(Set(remaining.map { $0.message.id }), ["r5", "r4", "r3", "u1", "u2"])
        // The cap is per (server, topic) — the other topic's single row is untouched.
        let other = try await store.messages(serverURL: "https://s.example", topic: "other")
        XCTAssertEqual(other.map { $0.message.id }, ["other"])
    }

    func testRetentionDisabledRulesDeleteNothing() async throws {
        try await store.upsert(makeMessage(id: "ancient", time: 1), serverURL: "https://s.example")
        try await store.markRead(true, serverURL: "https://s.example", topic: "alerts", messageID: "ancient")
        let policy = MessageStore.RetentionPolicy(tombstoneGraceDays: 0, readRetentionDays: 0, maxReadRowsPerTopic: 0)
        let deleted = try await store.enforceRetention(policy, now: testNow())
        XCTAssertEqual(deleted, 0)
    }
}
