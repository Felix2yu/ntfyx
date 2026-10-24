import Foundation
import GRDB

/// Actor-backed store for notification history.
/// All access is serialized by the actor; the single GRDB `DatabaseQueue` is
/// itself serial, and WAL mode keeps external readers (tests/tools) from blocking.
public actor MessageStore {
    private let db: DatabaseQueue

    /// Per-topic "everything up to this message time has been read", read once per topic.
    /// Backfilled rows at or below it are stored as read, so a replay of messages that the
    /// retention policy already pruned cannot refill the unread badge (see `markAllRead`).
    private var readWatermarks: [TopicRef: Int] = [:]

    // MARK: - Init

    public init(dbPath: String) throws {
        db = try HistoryDatabase.makeQueue(path: dbPath)
    }

    /// In-memory store for testing.
    static func inMemory() throws -> MessageStore {
        try MessageStore(dbPath: ":memory:")
    }

    /// Default on-disk location: ~/Library/Application Support/ntfyx/history.db
    public static var defaultDatabasePath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return appSupport.appendingPathComponent("ntfyx/history.db").path
    }

    // MARK: - Upsert

    /// Inserts a message. Existing rows are left untouched (keeps read/tombstone state),
    /// which makes poll replays idempotent and prevents deleted messages from "resurrecting".
    ///
    /// - Parameter asBackfill: true when the row comes from the server's cache (a poll replay or
    ///   a catch-up burst), false for a live delivery. A backfilled row at or below the topic's
    ///   read watermark is stored as read: retention removes read rows, so replaying the cache
    ///   brings back messages the user already read, and storing them unread is what made the
    ///   badge jump after a new subscription. A live message is never assumed read — it can well
    ///   land in the same second the topic was marked read.
    func upsert(
        _ message: NtfyMessage, serverURL: String, rawJSON: String? = nil, asBackfill: Bool = false
    ) throws {
        // Zero without a backfill, so the comparison below also yields "unread".
        var watermark = 0
        if asBackfill {
            watermark = try readWatermark(serverURL: serverURL, topic: message.topic)
        }
        try db.inDatabase { db in
            try Self.insertRow(
                db, message: message, serverURL: serverURL, rawJSON: rawJSON, readWatermark: watermark
            )
        }
    }

    /// The topic's read watermark, loaded from `sync_state` on first touch and kept in memory:
    /// every stored message needs it, and a replay can carry tens of thousands.
    private func readWatermark(serverURL: String, topic: String) throws -> Int {
        let ref = TopicRef(serverURL: serverURL, topic: topic)
        if let cached = readWatermarks[ref] { return cached }
        let watermark = try db.inDatabase { db in
            try Self.fetchWatermark(db, serverURL: serverURL, topic: topic)
        }
        readWatermarks[ref] = watermark
        return watermark
    }

    // MARK: - Action events (message_delete / message_clear)

    /// `WHERE` clause locating the row an action event targets. The event carries a freshly
    /// generated id of its own, so the target is the `sequence_id` the server echoes back —
    /// either a real sequence id or, for messages without one, the message id the publishing
    /// client put in the URL. The event id is matched as a last resort, for events published
    /// by older clients.
    ///
    /// Placeholder order: server url, topic, sequence id ×3, event id ×2. Every action-event
    /// statement has to go through this fragment, otherwise they stop agreeing on the row.
    private static let actionTargetWhere = """
    WHERE server_url = ? AND topic = ?
      AND (   (? IS NOT NULL AND (sequence_id = ? OR msg_id = ?))
           OR (? IS NOT NULL AND msg_id = ?))
    """

    private static func actionTargetArguments(
        serverURL: String,
        topic: String,
        sequenceID: String?,
        eventID: String?
    ) -> [DatabaseValueConvertible?] {
        [serverURL, topic, sequenceID, sequenceID, sequenceID, eventID, eventID]
    }

    /// Applies a server-side action event to its target message.
    /// `message_delete` tombstones the row; `message_clear` — the event the server
    /// publishes for `/<topic>/<seq>/read|clear` — only marks it read.
    /// - Returns: true if a row was affected.
    @discardableResult
    func applyActionEvent(_ event: NtfyMessage, serverURL: String) throws -> Bool {
        if event.event == NtfyMessage.clearEvent {
            return try applyReadEvent(
                serverURL: serverURL, topic: event.topic,
                targetSequenceID: event.sequenceId, targetMessageID: event.id
            )
        }
        return try applyDeleteEvent(
            serverURL: serverURL, topic: event.topic,
            targetSequenceID: event.sequenceId, targetMessageID: event.id
        )
    }

    /// The stored row's message id for an action event's target, or nil when the store has
    /// never seen that message. The event names its target by sequence id, so this is what
    /// maps it back to the id the message was delivered and bannered under.
    func targetMessageID(for event: NtfyMessage, serverURL: String) throws -> String? {
        try db.inDatabase { db in
            try Self.fetchTargetMessageID(
                db, serverURL: serverURL, topic: event.topic,
                sequenceID: event.sequenceId, eventID: event.id
            )
        }
    }

    /// Applies a replayed catch-up batch inside one transaction. A `since` replay can carry
    /// tens of thousands of events, and a commit per row would keep the store's serial queue
    /// busy — and the UI waiting on it — for minutes.
    /// - Parameters:
    ///   - readNotNewerThan: the newest message time this device held when the replay started
    ///     (0 when it held none). A row at or below that point is history the device has already
    ///     gone past — read here or on another device — so it comes in read instead of lighting up
    ///     the badge. The caller has to snapshot it before the first batch: the store's own
    ///     `MAX(time)` moves as the replay lands, and same-second rows in one burst would then
    ///     be filed as read message by message.
    /// - Returns: ids of the messages an action event in this batch withdrew, so their
    /// banners can be revoked in one call.
    func applyBatch(
        _ events: [NtfyMessage], serverURL: String, readNotNewerThan: Int = 0
    ) throws -> [String] {
        var revoked: [String] = []
        try db.inTransaction(.immediate) { db in
            for event in events {
                if event.isActionEvent {
                    try Self.applyActionEventRow(
                        db, event: event, serverURL: serverURL
                    )
                    if let id = try Self.fetchTargetMessageID(
                        db, serverURL: serverURL, topic: event.topic,
                        sequenceID: event.sequenceId, eventID: event.id
                    ) {
                        revoked.append(id)
                    }
                } else if event.event == "message" {
                    // The watermark is a primary-key point lookup inside the same
                    // transaction; the actor's in-memory cache is skipped here because
                    // this nonisolated SQL helper cannot touch actor state.
                    let watermark = max(
                        try Self.fetchWatermark(db, serverURL: serverURL, topic: event.topic),
                        readNotNewerThan
                    )
                    try Self.insertRow(
                        db, message: event, serverURL: serverURL,
                        rawJSON: nil, readWatermark: watermark
                    )
                }
            }
            return .commit
        }
        return revoked
    }

    /// Applies a server-side `message_delete` event by tombstoning the target message.
    /// - Returns: true if a row was affected.
    @discardableResult
    func applyDeleteEvent(serverURL: String, topic: String, targetSequenceID: String?, targetMessageID: String?) throws -> Bool {
        try db.inDatabase { db in
            try Self.applyDeleteRow(
                db, serverURL: serverURL, topic: topic,
                targetSequenceID: targetSequenceID, targetMessageID: targetMessageID
            )
        }
    }

    // MARK: - Read state

    func markRead(_ read: Bool, serverURL: String, topic: String, messageID: String) throws {
        try db.inDatabase { db in
            try db.execute(
                sql: "UPDATE messages SET is_read = ? WHERE server_url = ? AND topic = ? AND msg_id = ?",
                arguments: [read ? 1 : 0, serverURL, topic, messageID]
            )
        }
    }

    /// Marks many messages read in one transaction and returns the rows that were actually
    /// unread before, so the caller only revokes banners and syncs ids that really flipped.
    ///
    /// Deliberately row-scoped, unlike `markAllRead`: a scroll only ever shows a handful of
    /// messages, and moving the topic watermark up to `MAX(time)` would silently mark the
    /// unseen backlog read — including messages retention has not even pruned yet.
    func markReadBatch(_ rows: [StoredMessage]) throws -> [StoredMessage] {
        let unread = rows.filter { !$0.isRead }
        guard !unread.isEmpty else { return [] }

        try db.inTransaction(.immediate) { db in
            var index = 0
            while index < unread.count {
                let chunk = Array(unread[index..<min(index + Self.markReadChunk, unread.count)])
                var sql = "UPDATE messages SET is_read = 1 WHERE is_read = 0 AND ("
                var bindings: [DatabaseValueConvertible?] = []
                for row in chunk {
                    sql += "(server_url = ? AND topic = ? AND msg_id = ?) OR "
                    bindings.append(contentsOf: [row.serverURL, row.topic, row.message.id])
                }
                sql.removeLast(4)  // the trailing " OR "
                sql += ")"
                try db.execute(sql: sql, arguments: StatementArguments(bindings))
                index += chunk.count
            }
            return .commit
        }
        return unread
    }

    /// Three placeholders per row keeps one statement well under SQLite's variable limit.
    private static let markReadChunk = 150

    func markAllRead(_ read: Bool = true, serverURL: String, topic: String) throws {
        try db.inDatabase { db in
            try db.execute(
                sql: """
                UPDATE messages SET is_read = ?
                WHERE server_url = ? AND topic = ? AND is_deleted = 0 AND is_read != ?
                """,
                arguments: [read ? 1 : 0, serverURL, topic, read ? 1 : 0]
            )
        }

        try recordTopicRead(serverURL: serverURL, topic: topic, read: read)
    }

    /// Records how far the topic has been read: `markAllRead` means "everything I have is read",
    /// so the watermark becomes its newest row. Retention then erases those rows, and without
    /// this record a replay of the server cache would file them as unread again. Marking the
    /// topic unread clears the record instead, so the messages count as unread if they return.
    private func recordTopicRead(serverURL: String, topic: String, read: Bool) throws {
        var value = 0
        if read {
            value = try db.inDatabase { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(MAX(time), 0) FROM messages WHERE server_url = ? AND topic = ? AND is_deleted = 0",
                    arguments: [serverURL, topic]
                ) ?? 0
            }
        }

        // Monotonic while reading: an older batch can arrive after the watermark was raised,
        // and it still belongs to the range the user already went through.
        let sql = read
            ? """
            INSERT INTO sync_state (server_url, topic, max_read_time) VALUES (?, ?, ?)
            ON CONFLICT(server_url, topic) DO UPDATE SET
                max_read_time = MAX(sync_state.max_read_time, excluded.max_read_time)
            """
            : """
            INSERT INTO sync_state (server_url, topic, max_read_time) VALUES (?, ?, ?)
            ON CONFLICT(server_url, topic) DO UPDATE SET max_read_time = excluded.max_read_time
            """
        try db.inDatabase { db in
            try db.execute(sql: sql, arguments: [serverURL, topic, value])
        }

        let ref = TopicRef(serverURL: serverURL, topic: topic)
        readWatermarks[ref] = read
            ? max(try readWatermark(serverURL: serverURL, topic: topic), value)
            : 0
    }

    /// Applies a server-side `message_clear` event (the server's "mark as read"): the
    /// target stays in the list, only its read flag flips, so the unread badge drops.
    /// Matching works exactly like `applyDeleteEvent`.
    /// - Returns: true if a row was affected.
    @discardableResult
    func applyReadEvent(serverURL: String, topic: String, targetSequenceID: String?, targetMessageID: String?) throws -> Bool {
        try db.inDatabase { db in
            try Self.applyReadRow(
                db, serverURL: serverURL, topic: topic,
                targetSequenceID: targetSequenceID, targetMessageID: targetMessageID
            )
        }
    }

    // MARK: - Tombstoning

    /// Locally deletes (tombstones) a single message.
    @discardableResult
    func tombstoneMessage(serverURL: String, topic: String, messageID: String) throws -> Bool {
        try db.inDatabase { db in
            try db.execute(
                sql: "UPDATE messages SET is_deleted = 1, deleted_at = ? WHERE server_url = ? AND topic = ? AND msg_id = ?",
                arguments: [Int(Date().timeIntervalSince1970), serverURL, topic, messageID]
            )
            return db.changesCount > 0
        }
    }

    /// Locally clears (tombstones) all messages of a topic.
    func tombstoneAll(serverURL: String, topic: String) throws {
        try db.inDatabase { db in
            try db.execute(
                sql: "UPDATE messages SET is_deleted = 1, deleted_at = ? WHERE server_url = ? AND topic = ? AND is_deleted = 0",
                arguments: [Int(Date().timeIntervalSince1970), serverURL, topic]
            )
        }
    }

    /// Hard-removes a topic's messages and sync state. Used when a subscription is
    /// deleted from the config, so its unread rows cannot keep the menu bar badge lit
    /// with no UI left to clear them.
    func deleteTopic(serverURL: String, topic: String) throws {
        try db.inDatabase { db in
            try db.execute(
                sql: "DELETE FROM messages WHERE server_url = ? AND topic = ?",
                arguments: [serverURL, topic]
            )
            try db.execute(
                sql: "DELETE FROM sync_state WHERE server_url = ? AND topic = ?",
                arguments: [serverURL, topic]
            )
            // Undeliverable read marks must not outlive the topic they address.
            try db.execute(
                sql: "DELETE FROM pending_read WHERE server_url = ? AND topic = ?",
                arguments: [serverURL, topic]
            )
        }
        // The stored watermark is gone with the row, so the cached one has to go too —
        // otherwise re-adding the topic would file its replayed messages as read.
        readWatermarks.removeValue(forKey: TopicRef(serverURL: serverURL, topic: topic))
    }

    // MARK: - Retention (audit 2.4)

    /// Bounds how long history rows accumulate. Every rule can be disabled with 0.
    struct RetentionPolicy: Equatable, Sendable {
        /// Tombstones older than this are physically removed. Until then they must
        /// survive so a `since=all` poll replay cannot resurrect the deleted message.
        var tombstoneGraceDays: Int = 30
        /// Read messages older than this are removed (unread are always kept).
        var readRetentionDays: Int = 90
        /// Beyond the newest N live rows per topic, older read rows are removed.
        var maxReadRowsPerTopic: Int = 2000

        static let standard = RetentionPolicy()
    }

    /// Queued read marks only leave through a successful replay. A server that keeps
    /// refusing them (auth on, no usable token) would grow the outbox forever, so it is
    /// bounded by age like every other retention rule — a token configured later than
    /// this simply no longer syncs the oldest marks.
    static let pendingReadRetentionDays = 30

    /// Deletes the number of rows changed by the most recently completed statement.
    @discardableResult
    func enforceRetention(_ policy: RetentionPolicy = .standard, now: Date = Date()) throws -> Int {
        let nowSeconds = Int(now.timeIntervalSince1970)
        let daySeconds = 86_400

        var rules: [(sql: String, values: [Int])] = []
        if policy.tombstoneGraceDays > 0 {
            rules.append((
                "DELETE FROM messages WHERE is_deleted = 1 AND COALESCE(deleted_at, time) < ?",
                [nowSeconds - policy.tombstoneGraceDays * daySeconds]
            ))
        }
        if policy.readRetentionDays > 0 {
            rules.append((
                "DELETE FROM messages WHERE is_deleted = 0 AND is_read = 1 AND time < ?",
                [nowSeconds - policy.readRetentionDays * daySeconds]
            ))
        }
        if policy.maxReadRowsPerTopic > 0 {
            // Group-wise top-K trim: drop read rows that have at least N newer live
            // rows in the same topic. `GROUP BY 1` pins this to one aggregate group —
            // without it SQLite rejects the HAVING clause. Unread rows are never
            // dropped by the cap.
            rules.append((
                """
                DELETE FROM messages
                WHERE is_deleted = 0 AND is_read = 1 AND EXISTS (
                    SELECT 1, COUNT(*) FROM messages AS newer
                    WHERE newer.server_url = messages.server_url AND newer.topic = messages.topic
                      AND newer.is_deleted = 0
                      AND (newer.time > messages.time
                           OR (newer.time = messages.time AND newer.rowid_pk > messages.rowid_pk))
                    GROUP BY 1
                    HAVING COUNT(*) >= ?
                )
                """,
                [policy.maxReadRowsPerTopic]
            ))
        }
        // Unconditional: the outbox shrinks only through replay, so age is its only bound.
        rules.append((
            "DELETE FROM pending_read WHERE enqueued_at < ?",
            [nowSeconds - Self.pendingReadRetentionDays * daySeconds]
        ))

        return try db.inDatabase { db in
            // Each rule stays its own statement (and implicit transaction), matching
            // the pre-GRDB behavior: a later rule failing does not roll back earlier ones.
            var deleted = 0
            for rule in rules {
                try db.execute(sql: rule.sql, arguments: StatementArguments(rule.values))
                deleted += db.changesCount
            }
            return deleted
        }
    }

    /// Reclaims the file space left behind by large deletions. Expensive — call rarely.
    /// Runs outside any transaction (SQLite forbids VACUUM inside one).
    func vacuum() throws {
        try db.inDatabase { db in
            try db.execute(sql: "VACUUM")
        }
    }

    // MARK: - Queries

    /// Fetches messages newest first, with cursor pagination.
    /// - Parameters:
    ///   - topic: topic name, or `nil` to merge every topic stored for `serverURL`.
    ///   - limit: max rows to return.
    ///   - before: composite `(time, rowID)` cursor for "load older" (audit 2.3).
    ///   - onlyUnread: filter to unread messages only.
    ///   - searchText: substring match on title/message (case-insensitive).
    func messages(
        serverURL: String,
        topic: String?,
        limit: Int = 100,
        before: PageCursor? = nil,
        onlyUnread: Bool = false,
        searchText: String? = nil
    ) throws -> [StoredMessage] {
        try fetchMessages(
            serverURL: serverURL, topic: topic, limit: limit,
            before: before, onlyUnread: onlyUnread,
            search: searchText.map { Self.ftsTextFilter(columns: ["title", "message"], query: $0) }
        )
    }

    private func fetchMessages(
        serverURL: String,
        topic: String?,
        limit: Int,
        before: PageCursor?,
        onlyUnread: Bool,
        search: FtsTextFilter?
    ) throws -> [StoredMessage] {
        var sql = """
        SELECT server_url, topic, msg_id, sequence_id, event, time, message, title, priority,
               tags_json, click, actions_json, attachment_json, content_type, is_read, is_deleted, rowid_pk
        FROM messages
        WHERE server_url = ? AND is_deleted = 0
        """
        var bindings: [DatabaseValueConvertible?] = [serverURL]

        if let topic {
            sql += " AND topic = ?"
            bindings.append(topic)
        }
        if let before {
            sql += " AND (time < ? OR (time = ? AND rowid_pk < ?))"
            bindings.append(contentsOf: [before.time, before.time, Int(before.rowID)])
        }
        if onlyUnread {
            sql += " AND is_read = 0"
        }
        if let filter = search {
            sql += filter.sql
            bindings.append(contentsOf: [filter.pattern, filter.pattern])
        }
        sql += " ORDER BY time DESC, rowid_pk DESC LIMIT ?"
        bindings.append(limit)

        return try db.inDatabase { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(bindings)).map { row in
                // An unscoped page spans every topic, so the row itself carries the pair;
                // a scoped page re-reads the values it filtered on.
                let rowServerURL = row["server_url"] as String? ?? ""
                let rowTopic = (row["topic"] as String?) ?? topic ?? ""
                return try Self.storedMessage(from: row, serverURL: rowServerURL, topic: rowTopic)
            }
        }
    }

    /// Substring search across every topic (title, body and topic name), newest first.
    /// - Parameters:
    ///   - limit: max rows to return.
    ///   - before: composite `(time, rowID)` cursor for "load older" (audit 2.3).
    func searchAll(query: String, limit: Int = 200, before: PageCursor? = nil) throws -> [StoredMessage] {
        try fetchAll(
            limit: limit, before: before,
            search: Self.ftsTextFilter(columns: ["title", "message", "topic"], query: query)
        )
    }

    private func fetchAll(limit: Int, before: PageCursor?, search: FtsTextFilter) throws -> [StoredMessage] {
        var sql = """
        SELECT server_url, topic, msg_id, sequence_id, event, time, message, title, priority,
               tags_json, click, actions_json, attachment_json, content_type, is_read, is_deleted, rowid_pk
        FROM messages
        WHERE is_deleted = 0
        """
        var bindings: [DatabaseValueConvertible?] = []
        sql += search.sql
        bindings.append(contentsOf: [search.pattern, search.pattern, search.pattern])

        if let before {
            sql += " AND (time < ? OR (time = ? AND rowid_pk < ?))"
            bindings.append(contentsOf: [before.time, before.time, Int(before.rowID)])
        }
        sql += " ORDER BY time DESC, rowid_pk DESC LIMIT ?"
        bindings.append(limit)

        return try db.inDatabase { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(bindings)).map { row in
                // server_url/topic come from the row itself: unlike messages() this spans
                // every topic, so there is no caller-supplied value to fall back on.
                let rowServerURL = row["server_url"] as String? ?? ""
                let rowTopic = row["topic"] as String? ?? ""
                return try Self.storedMessage(from: row, serverURL: rowServerURL, topic: rowTopic)
            }
        }
    }

    /// Whether a physical row exists regardless of read/tombstone flags (an expired
    /// tombstone must be gone for good; UI queries filter them out and can't tell).
    func rawRowExists(serverURL: String, topic: String, messageID: String) throws -> Bool {
        try db.inDatabase { db in
            try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM messages WHERE server_url = ? AND topic = ? AND msg_id = ?",
                arguments: [serverURL, topic, messageID]
            ) != nil
        }
    }

    /// All (server, topic) pairs that have any history rows, subscribed or not.
    func trackedTopics() throws -> Set<TopicRef> {
        try db.inDatabase { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT DISTINCT server_url, topic FROM messages"
            )
            return Set(rows.map {
                TopicRef(
                    serverURL: $0["server_url"] as String? ?? "",
                    topic: $0["topic"] as String? ?? ""
                )
            })
        }
    }

    /// Unread counts per topic, excluding tombstoned messages.
    func unreadCountsByTopic() throws -> [TopicRef: Int] {
        try db.inDatabase { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT server_url, topic, COUNT(*) AS count FROM messages
                WHERE is_deleted = 0 AND is_read = 0
                GROUP BY server_url, topic
                """
            )
            return rows.reduce(into: [TopicRef: Int]()) { counts, row in
                let ref = TopicRef(
                    serverURL: row["server_url"] as String? ?? "",
                    topic: row["topic"] as String? ?? ""
                )
                counts[ref] = row["count"] as Int? ?? 0
            }
        }
    }

    /// Number of non-deleted messages stored for a topic.
    func messageCount(serverURL: String, topic: String) throws -> Int {
        try db.inDatabase { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages WHERE server_url = ? AND topic = ? AND is_deleted = 0",
                arguments: [serverURL, topic]
            ) ?? 0
        }
    }

    // MARK: - Pending read sync (outbox)

    /// Queues read marks the server has not accepted yet. Marking read is local-first
    /// (`markRead`/`markReadBatch` write before the /read request leaves), so a mark made
    /// while offline — or rejected mid-chunk by a rate limit — has to survive here until
    /// a reconnect replays it. Idempotent by target id.
    func enqueuePendingReads(serverURL: String, topic: String, ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.inTransaction(.immediate) { db in
            let now = Int(Date().timeIntervalSince1970)
            for id in ids {
                try db.execute(
                    sql: """
                    INSERT INTO pending_read (server_url, topic, target_id, enqueued_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(server_url, topic, target_id) DO UPDATE SET enqueued_at = excluded.enqueued_at
                    """,
                    arguments: [serverURL, topic, id, now]
                )
            }
            return .commit
        }
    }

    /// All queued read targets of one server, grouped by topic, oldest first — the input
    /// of the drain that replays them once the server is reachable again.
    func pendingReadIDs(serverURL: String) throws -> [String: [String]] {
        try db.inDatabase { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT topic, target_id FROM pending_read
                WHERE server_url = ? ORDER BY topic, enqueued_at, target_id
                """,
                arguments: [serverURL]
            )
            return Dictionary(grouping: rows, by: { ($0["topic"] as String?) ?? "" })
                .mapValues { $0.compactMap { $0["target_id"] as String? } }
        }
    }

    /// Drops the targets a drain got the server to accept.
    func removePendingReads(serverURL: String, topic: String, ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.inTransaction(.immediate) { db in
            for id in ids {
                try db.execute(
                    sql: "DELETE FROM pending_read WHERE server_url = ? AND topic = ? AND target_id = ?",
                    arguments: [serverURL, topic, id]
                )
            }
            return .commit
        }
    }

    // MARK: - Sync state

    /// The newest message time this device has ever stored for a topic — its frontier in the
    /// server's timeline. Tombstones count: that row really was delivered here.
    func maxStoredMessageTime(serverURL: String, topic: String) throws -> Int? {
        try db.inDatabase { db in
            try Int.fetchOne(
                db,
                sql: "SELECT MAX(time) FROM messages WHERE server_url = ? AND topic = ?",
                arguments: [serverURL, topic]
            )
        }
    }

    func latestSyncedInfo(serverURL: String, topic: String) throws -> (id: String?, time: Int)? {
        try db.inDatabase { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT last_synced_id, last_synced_time FROM sync_state WHERE server_url = ? AND topic = ?",
                arguments: [serverURL, topic]
            ) else { return nil }
            return (id: row["last_synced_id"] as String?, time: row["last_synced_time"] as Int? ?? 0)
        }
    }

    func setSyncedInfo(serverURL: String, topic: String, id: String?, time: Int) throws {
        try db.inDatabase { db in
            try db.execute(
                sql: """
                INSERT INTO sync_state (server_url, topic, last_synced_id, last_synced_time, last_sync_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(server_url, topic) DO UPDATE SET
                    last_synced_id = excluded.last_synced_id,
                    last_synced_time = excluded.last_synced_time,
                    last_sync_at = excluded.last_sync_at
                """,
                arguments: StatementArguments(
                    [serverURL, topic, id, time, Int(Date().timeIntervalSince1970)] as [DatabaseValueConvertible?]
                )
            )
        }
    }

    // MARK: - SQL helpers

    /// A ready-to-bind substring search over the trigram FTS table: the SQL fragment
    /// (appended to the outer `messages` query) plus the LIKE pattern to bind once per
    /// searched column.
    struct FtsTextFilter: Equatable {
        let sql: String
        let pattern: String
    }

    /// Builds the `rowid_pk IN (SELECT rowid FROM messages_fts WHERE <columns> LIKE …)`
    /// filter. All text search runs *inside* the trigram FTS5 virtual table — never as a
    /// LIKE scan over `messages` — and the predicates are column-level (the virtual table
    /// has no single text column, so `messages_fts LIKE ?` matches nothing).
    ///
    /// Two variants of the same single route:
    /// - User text without LIKE metacharacters (`% _ \`): plain `LIKE '%…%'`, which the
    ///   trigram tokenizer accelerates by seeking ≥3-character windows (per-column
    ///   MULTI-INDEX OR); semantics are already literal, so no ESCAPE is needed.
    /// - User text containing a metacharacter (e.g. `100%`, `build_job`): the wildcards
    ///   are escaped and `ESCAPE '\'` is added. FTS5 cannot accelerate a LIKE that has an
    ///   ESCAPE clause (verified against the system SQLite), so this scans the FTS index,
    ///   but it keeps `%`/`_` literal — acceleration is never traded for wrong results.
    static func ftsTextFilter(columns: [String], query: String) -> FtsTextFilter {
        let needsEscape = query.contains("\\") || query.contains("%") || query.contains("_")
        let pattern = needsEscape ? likePattern(query) : "%\(query)%"
        let comparator = needsEscape ? "LIKE ? ESCAPE '\\'" : "LIKE ?"
        let predicates = columns
            .map { "\($0) \(comparator)" }
            .joined(separator: " OR ")
        return FtsTextFilter(
            sql: " AND rowid_pk IN (SELECT rowid FROM messages_fts WHERE \(predicates))",
            pattern: pattern
        )
    }

    /// Case-insensitive substring LIKE pattern with the wildcards in the user text escaped.
    static func likePattern(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    private static func encodedJSON<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodedJSON<T: Decodable>(_ type: T.Type, from string: String?) -> T? {
        guard let string, let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// The topic's read watermark from `sync_state` (SQL helper, no actor state).
    private static func fetchWatermark(_ db: Database, serverURL: String, topic: String) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT max_read_time FROM sync_state WHERE server_url = ? AND topic = ?",
            arguments: [serverURL, topic]
        ) ?? 0
    }

    /// Inserts one message row. `INSERT OR IGNORE` keeps existing read/tombstone state.
    private static func insertRow(
        _ db: Database,
        message: NtfyMessage,
        serverURL: String,
        rawJSON: String?,
        readWatermark: Int
    ) throws {
        let sql = """
        INSERT OR IGNORE INTO messages
            (server_url, topic, msg_id, sequence_id, event, time, message, title, priority,
             tags_json, click, actions_json, attachment_json, content_type, is_read, is_deleted, raw_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
        """
        let arguments: [DatabaseValueConvertible?] = [
            serverURL,
            message.topic,
            message.id,
            message.sequenceId,
            message.event,
            message.time,
            message.message,
            message.title,
            message.priority,
            encodedJSON(message.tags),
            message.click,
            encodedJSON(message.actions),
            encodedJSON(message.attachment),
            message.contentType,
            message.time <= readWatermark ? 1 : 0,
            rawJSON
        ]
        try db.execute(sql: sql, arguments: StatementArguments(arguments))
    }

    /// The message id an action event's target row carries (SQL helper).
    private static func fetchTargetMessageID(
        _ db: Database,
        serverURL: String,
        topic: String,
        sequenceID: String?,
        eventID: String?
    ) throws -> String? {
        let sql = """
        SELECT msg_id FROM messages
        \(actionTargetWhere)
        LIMIT 1
        """
        let id = try String.fetchOne(
            db,
            sql: sql,
            arguments: StatementArguments(actionTargetArguments(
                serverURL: serverURL, topic: topic,
                sequenceID: sequenceID, eventID: eventID
            ))
        )
        return (id?.isEmpty == false) ? id : nil
    }

    /// Routes one action event inside an open transaction/connection (SQL helper).
    private static func applyActionEventRow(
        _ db: Database,
        event: NtfyMessage,
        serverURL: String
    ) throws {
        if event.event == NtfyMessage.clearEvent {
            _ = try applyReadRow(
                db, serverURL: serverURL, topic: event.topic,
                targetSequenceID: event.sequenceId, targetMessageID: event.id
            )
        } else {
            _ = try applyDeleteRow(
                db, serverURL: serverURL, topic: event.topic,
                targetSequenceID: event.sequenceId, targetMessageID: event.id
            )
        }
    }

    /// Marks the row a `message_clear` event targets as read (SQL helper).
    /// `is_read = 0` is what keeps a replayed event from re-marking a message the user already
    /// read: `since=<id>` is exclusive, so the action events behind the cursor come back with
    /// every poll, and an already-read row has to be left alone.
    /// - Returns: true if a row was affected.
    private static func applyReadRow(
        _ db: Database,
        serverURL: String,
        topic: String,
        targetSequenceID: String?,
        targetMessageID: String?
    ) throws -> Bool {
        try db.execute(
            sql: """
            UPDATE messages
            SET is_read = 1
            \(actionTargetWhere)
              AND is_deleted = 0
              AND is_read = 0
            """,
            arguments: StatementArguments(actionTargetArguments(
                serverURL: serverURL, topic: topic,
                sequenceID: targetSequenceID, eventID: targetMessageID
            ))
        )
        return db.changesCount > 0
    }

    /// Tombstones the row a `message_delete` event targets (SQL helper). Guarded on
    /// `is_deleted = 0` like `applyReadRow`: re-applying a replayed event would also refresh
    /// `deleted_at`, pushing the tombstone's expiry out every time it came back.
    /// - Returns: true if a row was affected.
    private static func applyDeleteRow(
        _ db: Database,
        serverURL: String,
        topic: String,
        targetSequenceID: String?,
        targetMessageID: String?
    ) throws -> Bool {
        var arguments: [DatabaseValueConvertible?] = [Int(Date().timeIntervalSince1970)]
        arguments.append(contentsOf: actionTargetArguments(
            serverURL: serverURL, topic: topic,
            sequenceID: targetSequenceID, eventID: targetMessageID
        ))
        try db.execute(
            sql: """
            UPDATE messages
            SET is_deleted = 1, deleted_at = ?
            \(actionTargetWhere)
              AND is_deleted = 0
            """,
            arguments: StatementArguments(arguments)
        )
        return db.changesCount > 0
    }

    private static func storedMessage(from row: Row, serverURL: String, topic: String) throws -> StoredMessage {
        let message = NtfyMessage(
            id: row["msg_id"] as String? ?? "",
            time: row["time"] as Int? ?? 0,
            event: row["event"] as String? ?? "message",
            topic: row["topic"] as String? ?? topic,
            message: row["message"] as String?,
            title: row["title"] as String?,
            priority: row["priority"] as Int?,
            tags: decodedJSON([String].self, from: row["tags_json"] as String?),
            click: row["click"] as String?,
            actions: decodedJSON([NtfyMessage.NtfyAction].self, from: row["actions_json"] as String?),
            attachment: decodedJSON(NtfyMessage.NtfyAttachment.self, from: row["attachment_json"] as String?),
            contentType: row["content_type"] as String?,
            sequenceId: row["sequence_id"] as String?
        )
        return StoredMessage(
            serverURL: row["server_url"] as String? ?? serverURL,
            topic: topic,
            message: message,
            isRead: (row["is_read"] as Int? ?? 0) == 1,
            isDeleted: (row["is_deleted"] as Int? ?? 0) == 1,
            rowID: Int64(row["rowid_pk"] as Int? ?? 0)
        )
    }
}
