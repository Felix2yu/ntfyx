import Foundation

/// Actor-backed SQLite store for notification history.
/// All access is serialized by the actor; the single SQLite connection is
/// opened with FULLMUTEX and WAL mode for safe concurrent reads from tests/tools.
actor MessageStore {
    private let db: SQLiteDatabase

    /// Per-topic "everything up to this message time has been read", read once per topic.
    /// Backfilled rows at or below it are stored as read, so a replay of messages that the
    /// retention policy already pruned cannot refill the unread badge (see `markAllRead`).
    private var readWatermarks: [TopicRef: Int] = [:]

    // MARK: - DDL

    private static let schema = """
    PRAGMA journal_mode=WAL;
    PRAGMA busy_timeout=5000;
    PRAGMA synchronous=NORMAL;

    CREATE TABLE IF NOT EXISTS messages (
        rowid_pk        INTEGER PRIMARY KEY AUTOINCREMENT,
        server_url      TEXT    NOT NULL,
        topic           TEXT    NOT NULL,
        msg_id          TEXT    NOT NULL,
        sequence_id     TEXT,
        event           TEXT    NOT NULL DEFAULT 'message',
        time            INTEGER NOT NULL,
        message         TEXT,
        title           TEXT,
        priority        INTEGER,
        tags_json       TEXT,
        click           TEXT,
        actions_json    TEXT,
        attachment_json TEXT,
        content_type    TEXT,
        is_read         INTEGER NOT NULL DEFAULT 0,
        is_deleted      INTEGER NOT NULL DEFAULT 0,
        deleted_at      INTEGER,
        raw_json        TEXT,
        UNIQUE(server_url, topic, msg_id)
    );
    CREATE INDEX IF NOT EXISTS idx_msg_topic_time ON messages(server_url, topic, time DESC);
    CREATE INDEX IF NOT EXISTS idx_msg_unread ON messages(server_url, topic) WHERE is_read = 0 AND is_deleted = 0;
    CREATE INDEX IF NOT EXISTS idx_msg_sequence ON messages(server_url, topic, sequence_id) WHERE sequence_id IS NOT NULL;

    CREATE TABLE IF NOT EXISTS sync_state (
        server_url       TEXT NOT NULL,
        topic            TEXT NOT NULL,
        last_synced_id   TEXT,
        last_synced_time INTEGER,
        last_sync_at     INTEGER,
        max_read_time    INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(server_url, topic)
    );
    """

    // MARK: - Init

    init(dbPath: String) throws {
        if dbPath != ":memory:" {
            let directory = (dbPath as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
        }
        db = try SQLiteDatabase(path: dbPath)
        try db.execute(Self.schema)
        try Self.migrate(db)
    }

    /// Adds columns that `CREATE TABLE IF NOT EXISTS` cannot retrofit: an existing database
    /// keeps its old table, so each later column needs its own ALTER. Re-running is normal —
    /// SQLite answers it with "duplicate column name", which means the table is current.
    private static func migrate(_ db: SQLiteDatabase) throws {
        do {
            try db.execute("ALTER TABLE sync_state ADD COLUMN max_read_time INTEGER NOT NULL DEFAULT 0")
        } catch let error as SQLiteError {
            guard case .execFailed(let message) = error,
                  message.contains("duplicate column name") else { throw error }
        }
    }

    /// In-memory store for testing.
    static func inMemory() throws -> MessageStore {
        try MessageStore(dbPath: ":memory:")
    }

    /// Default on-disk location: ~/Library/Application Support/ntfyx/history.db
    static var defaultDatabasePath: String {
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
        let sql = """
        INSERT OR IGNORE INTO messages
            (server_url, topic, msg_id, sequence_id, event, time, message, title, priority,
             tags_json, click, actions_json, attachment_json, content_type, is_read, is_deleted, raw_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
        """
        let statement = try db.prepare(sql)
        defer { statement.finalize() }

        try statement.bindText(serverURL, at: 1)
        try statement.bindText(message.topic, at: 2)
        try statement.bindText(message.id, at: 3)
        try statement.bindOptionalText(message.sequenceId, at: 4)
        try statement.bindText(message.event, at: 5)
        try statement.bindInt(message.time, at: 6)
        try statement.bindOptionalText(message.message, at: 7)
        try statement.bindOptionalText(message.title, at: 8)
        try statement.bindOptionalInt(message.priority, at: 9)
        try statement.bindOptionalText(Self.encodedJSON(message.tags), at: 10)
        try statement.bindOptionalText(message.click, at: 11)
        try statement.bindOptionalText(Self.encodedJSON(message.actions), at: 12)
        try statement.bindOptionalText(Self.encodedJSON(message.attachment), at: 13)
        try statement.bindOptionalText(message.contentType, at: 14)
        // Zero without a backfill, so the comparison below also yields "unread".
        var watermark = 0
        if asBackfill {
            watermark = try readWatermark(serverURL: serverURL, topic: message.topic)
        }
        try statement.bindInt(message.time <= watermark ? 1 : 0, at: 15)
        try statement.bindOptionalText(rawJSON, at: 16)
        try statement.run()
    }

    /// The topic's read watermark, loaded from `sync_state` on first touch and kept in memory:
    /// every stored message needs it, and a replay can carry tens of thousands.
    private func readWatermark(serverURL: String, topic: String) throws -> Int {
        let ref = TopicRef(serverURL: serverURL, topic: topic)
        if let cached = readWatermarks[ref] { return cached }
        let rows: [Int] = try db.query(
            "SELECT max_read_time FROM sync_state WHERE server_url = ? AND topic = ?",
            bind: { statement in
                try statement.bindText(serverURL, at: 1)
                try statement.bindText(topic, at: 2)
            },
            row: { statement in statement.columnInt(0) ?? 0 }
        )
        let watermark = rows.first ?? 0
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

    private func bindActionTarget(
        _ statement: SQLiteStatement,
        offset: Int32,
        serverURL: String,
        topic: String,
        sequenceID: String?,
        eventID: String?
    ) throws {
        try statement.bindText(serverURL, at: offset)
        try statement.bindText(topic, at: offset + 1)
        try statement.bindOptionalText(sequenceID, at: offset + 2)
        try statement.bindOptionalText(sequenceID, at: offset + 3)
        try statement.bindOptionalText(sequenceID, at: offset + 4)
        try statement.bindOptionalText(eventID, at: offset + 5)
        try statement.bindOptionalText(eventID, at: offset + 6)
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
        let sql = """
        SELECT msg_id FROM messages
        \(Self.actionTargetWhere)
        LIMIT 1
        """
        let ids = try db.query(sql, bind: { statement in
            try self.bindActionTarget(
                statement, offset: 1,
                serverURL: serverURL, topic: event.topic,
                sequenceID: event.sequenceId, eventID: event.id
            )
        }, row: { statement in
            statement.columnText(0) ?? ""
        })
        return ids.first(where: { !$0.isEmpty })
    }

    /// Applies a replayed catch-up batch inside one transaction. A `since` replay can carry
    /// tens of thousands of events, and a commit per row would keep the store's serial queue
    /// busy — and the UI waiting on it — for minutes.
    /// - Returns: ids of the messages an action event in this batch withdrew, so their
    ///   banners can be revoked in one call.
    func applyBatch(_ events: [NtfyMessage], serverURL: String) throws -> [String] {
        try db.transaction {
            var revoked: [String] = []
            for event in events {
                if event.isActionEvent {
                    try applyActionEvent(event, serverURL: serverURL)
                    if let id = try targetMessageID(for: event, serverURL: serverURL) {
                        revoked.append(id)
                    }
                } else if event.event == "message" {
                    try upsert(event, serverURL: serverURL, asBackfill: true)
                }
            }
            return revoked
        }
    }

    /// Applies a server-side `message_delete` event by tombstoning the target message.
    /// - Returns: true if a row was affected.
    @discardableResult
    func applyDeleteEvent(serverURL: String, topic: String, targetSequenceID: String?, targetMessageID: String?) throws -> Bool {
        let sql = """
        UPDATE messages
        SET is_deleted = 1, deleted_at = ?
        \(Self.actionTargetWhere)
        """
        let statement = try db.prepare(sql)
        defer { statement.finalize() }

        try statement.bindInt(Int(Date().timeIntervalSince1970), at: 1)
        try bindActionTarget(
            statement, offset: 2,
            serverURL: serverURL, topic: topic,
            sequenceID: targetSequenceID, eventID: targetMessageID
        )
        try statement.run()
        return db.changesCount > 0
    }

    // MARK: - Read state

    func markRead(_ read: Bool, serverURL: String, topic: String, messageID: String) throws {
        let sql = "UPDATE messages SET is_read = ? WHERE server_url = ? AND topic = ? AND msg_id = ?"
        let statement = try db.prepare(sql)
        defer { statement.finalize() }
        try statement.bindInt(read ? 1 : 0, at: 1)
        try statement.bindText(serverURL, at: 2)
        try statement.bindText(topic, at: 3)
        try statement.bindText(messageID, at: 4)
        try statement.run()
    }

    func markAllRead(_ read: Bool = true, serverURL: String, topic: String) throws {
        let sql = "UPDATE messages SET is_read = ? WHERE server_url = ? AND topic = ? AND is_deleted = 0"
        let statement = try db.prepare(sql)
        defer { statement.finalize() }
        try statement.bindInt(read ? 1 : 0, at: 1)
        try statement.bindText(serverURL, at: 2)
        try statement.bindText(topic, at: 3)
        try statement.run()

        try recordTopicRead(serverURL: serverURL, topic: topic, read: read)
    }

    /// Records how far the topic has been read: `markAllRead` means "everything I have is read",
    /// so the watermark becomes its newest row. Retention then erases those rows, and without
    /// this record a replay of the server cache would file them as unread again. Marking the
    /// topic unread clears the record instead, so the messages count as unread if they return.
    private func recordTopicRead(serverURL: String, topic: String, read: Bool) throws {
        var value = 0
        if read {
            let rows: [Int] = try db.query(
                "SELECT COALESCE(MAX(time), 0) FROM messages WHERE server_url = ? AND topic = ? AND is_deleted = 0",
                bind: { statement in
                    try statement.bindText(serverURL, at: 1)
                    try statement.bindText(topic, at: 2)
                },
                row: { statement in statement.columnInt(0) ?? 0 }
            )
            value = rows.first ?? 0
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
        let statement = try db.prepare(sql)
        defer { statement.finalize() }
        try statement.bindText(serverURL, at: 1)
        try statement.bindText(topic, at: 2)
        try statement.bindInt(value, at: 3)
        try statement.run()

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
        let sql = """
        UPDATE messages
        SET is_read = 1
        \(Self.actionTargetWhere)
          AND is_deleted = 0
        """
        let statement = try db.prepare(sql)
        defer { statement.finalize() }

        try bindActionTarget(
            statement, offset: 1,
            serverURL: serverURL, topic: topic,
            sequenceID: targetSequenceID, eventID: targetMessageID
        )
        try statement.run()
        return db.changesCount > 0
    }

    // MARK: - Tombstoning

    /// Locally deletes (tombstones) a single message.
    @discardableResult
    func tombstoneMessage(serverURL: String, topic: String, messageID: String) throws -> Bool {
        let sql = "UPDATE messages SET is_deleted = 1, deleted_at = ? WHERE server_url = ? AND topic = ? AND msg_id = ?"
        let statement = try db.prepare(sql)
        defer { statement.finalize() }
        try statement.bindInt(Int(Date().timeIntervalSince1970), at: 1)
        try statement.bindText(serverURL, at: 2)
        try statement.bindText(topic, at: 3)
        try statement.bindText(messageID, at: 4)
        try statement.run()
        return db.changesCount > 0
    }

    /// Locally clears (tombstones) all messages of a topic.
    func tombstoneAll(serverURL: String, topic: String) throws {
        let sql = "UPDATE messages SET is_deleted = 1, deleted_at = ? WHERE server_url = ? AND topic = ? AND is_deleted = 0"
        let statement = try db.prepare(sql)
        defer { statement.finalize() }
        try statement.bindInt(Int(Date().timeIntervalSince1970), at: 1)
        try statement.bindText(serverURL, at: 2)
        try statement.bindText(topic, at: 3)
        try statement.run()
    }

    /// Hard-removes a topic's messages and sync state. Used when a subscription is
    /// deleted from the config, so its unread rows cannot keep the menu bar badge lit
    /// with no UI left to clear them.
    func deleteTopic(serverURL: String, topic: String) throws {
        for sql in [
            "DELETE FROM messages WHERE server_url = ? AND topic = ?",
            "DELETE FROM sync_state WHERE server_url = ? AND topic = ?",
        ] {
            let statement = try db.prepare(sql)
            defer { statement.finalize() }
            try statement.bindText(serverURL, at: 1)
            try statement.bindText(topic, at: 2)
            try statement.run()
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

    /// Deletes the number of rows changed by the most recently completed statement.
    @discardableResult
    func enforceRetention(_ policy: RetentionPolicy = .standard, now: Date = Date()) throws -> Int {
        let nowSeconds = Int(now.timeIntervalSince1970)
        let daySeconds = 86_400
        var deleted = 0

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

        for rule in rules {
            let statement = try db.prepare(rule.sql)
            defer { statement.finalize() }
            for (index, value) in rule.values.enumerated() {
                try statement.bindInt(value, at: Int32(index + 1))
            }
            try statement.run()
            deleted += db.changesCount
        }
        return deleted
    }

    /// Reclaims the file space left behind by large deletions. Expensive — call rarely.
    func vacuum() throws {
        try db.execute("VACUUM;")
    }

    // MARK: - Queries

    /// Fetches messages of a topic, newest first, with cursor pagination.
    /// - Parameters:
    ///   - limit: max rows to return.
    ///   - before: composite `(time, rowID)` cursor for "load older" (audit 2.3).
    ///   - onlyUnread: filter to unread messages only.
    ///   - searchText: substring match on title/message (case-insensitive).
    func messages(
        serverURL: String,
        topic: String,
        limit: Int = 100,
        before: PageCursor? = nil,
        onlyUnread: Bool = false,
        searchText: String? = nil
    ) throws -> [StoredMessage] {
        var sql = """
        SELECT server_url, topic, msg_id, sequence_id, event, time, message, title, priority,
               tags_json, click, actions_json, attachment_json, content_type, is_read, is_deleted, rowid_pk
        FROM messages
        WHERE server_url = ? AND topic = ? AND is_deleted = 0
        """
        var bindings: [SQLValue] = [.text(serverURL), .text(topic)]

        if let before {
            sql += " AND (time < ? OR (time = ? AND rowid_pk < ?))"
            bindings.append(.int(before.time))
            bindings.append(.int(before.time))
            bindings.append(.int(Int(before.rowID)))
        }
        if onlyUnread {
            sql += " AND is_read = 0"
        }
        if let searchText, !searchText.isEmpty {
            sql += " AND (title LIKE ? ESCAPE '\\' OR message LIKE ? ESCAPE '\\')"
            let pattern = Self.likePattern(searchText)
            bindings.append(.text(pattern))
            bindings.append(.text(pattern))
        }
        sql += " ORDER BY time DESC, rowid_pk DESC LIMIT ?"
        bindings.append(.int(limit))

        let statement = try db.prepare(sql)
        defer { statement.finalize() }
        for (offset, value) in bindings.enumerated() {
            try value.bind(to: statement, at: Int32(offset + 1))
        }

        var results: [StoredMessage] = []
        while try statement.step() {
            results.append(try Self.storedMessage(from: statement, serverURL: serverURL, topic: topic))
        }
        return results
    }

    /// Substring search across every topic (title, body and topic name), newest first.
    /// - Parameters:
    ///   - limit: max rows to return.
    ///   - before: composite `(time, rowID)` cursor for "load older" (audit 2.3).
    func searchAll(query: String, limit: Int = 200, before: PageCursor? = nil) throws -> [StoredMessage] {
        var sql = """
        SELECT server_url, topic, msg_id, sequence_id, event, time, message, title, priority,
               tags_json, click, actions_json, attachment_json, content_type, is_read, is_deleted, rowid_pk
        FROM messages
        WHERE is_deleted = 0
          AND (title LIKE ? ESCAPE '\\' OR message LIKE ? ESCAPE '\\' OR topic LIKE ? ESCAPE '\\')
        """
        let pattern = Self.likePattern(query)
        var bindings: [SQLValue] = [.text(pattern), .text(pattern), .text(pattern)]

        if let before {
            sql += " AND (time < ? OR (time = ? AND rowid_pk < ?))"
            bindings.append(.int(before.time))
            bindings.append(.int(before.time))
            bindings.append(.int(Int(before.rowID)))
        }
        sql += " ORDER BY time DESC, rowid_pk DESC LIMIT ?"
        bindings.append(.int(limit))

        let statement = try db.prepare(sql)
        defer { statement.finalize() }
        for (offset, value) in bindings.enumerated() {
            try value.bind(to: statement, at: Int32(offset + 1))
        }

        var results: [StoredMessage] = []
        while try statement.step() {
            // server_url/topic come from the row itself: unlike messages() this spans
            // every topic, so there is no caller-supplied value to fall back on.
            let serverURL = statement.columnText(0) ?? ""
            let topic = statement.columnText(1) ?? ""
            results.append(try Self.storedMessage(from: statement, serverURL: serverURL, topic: topic))
        }
        return results
    }

    /// Whether a physical row exists regardless of read/tombstone flags (an expired
    /// tombstone must be gone for good; UI queries filter them out and can't tell).
    func rawRowExists(serverURL: String, topic: String, messageID: String) throws -> Bool {
        let rows: [()] = try db.query(
            "SELECT 1 FROM messages WHERE server_url = ? AND topic = ? AND msg_id = ?",
            bind: { statement in
                try statement.bindText(serverURL, at: 1)
                try statement.bindText(topic, at: 2)
                try statement.bindText(messageID, at: 3)
            },
            row: { _ in () }
        )
        return !rows.isEmpty
    }

    /// All (server, topic) pairs that have any history rows, subscribed or not.
    func trackedTopics() throws -> Set<TopicRef> {        let sql = "SELECT DISTINCT server_url, topic FROM messages"
        let rows = try db.query(sql, bind: { _ in }, row: { statement -> TopicRef in
            TopicRef(serverURL: statement.columnText(0) ?? "", topic: statement.columnText(1) ?? "")
        })
        return Set(rows)
    }

    /// Unread counts per topic, excluding tombstoned messages.
    func unreadCountsByTopic() throws -> [TopicRef: Int] {
        let sql = """
        SELECT server_url, topic, COUNT(*) FROM messages
        WHERE is_deleted = 0 AND is_read = 0
        GROUP BY server_url, topic
        """
        let rows = try db.query(sql, bind: { _ in }, row: { statement -> (TopicRef, Int) in
            let serverURL = statement.columnText(0) ?? ""
            let topic = statement.columnText(1) ?? ""
            let count = statement.columnInt(2) ?? 0
            return (TopicRef(serverURL: serverURL, topic: topic), count)
        })
        return rows.reduce(into: [TopicRef: Int]()) { $0[$1.0] = $1.1 }
    }

    /// Number of non-deleted messages stored for a topic.
    func messageCount(serverURL: String, topic: String) throws -> Int {
        let sql = "SELECT COUNT(*) FROM messages WHERE server_url = ? AND topic = ? AND is_deleted = 0"
        let rows = try db.query(sql, bind: { statement in
            try statement.bindText(serverURL, at: 1)
            try statement.bindText(topic, at: 2)
        }, row: { statement -> Int in
            statement.columnInt(0) ?? 0
        })
        return rows.first ?? 0
    }

    // MARK: - Sync state

    func latestSyncedInfo(serverURL: String, topic: String) throws -> (id: String?, time: Int)? {
        let sql = "SELECT last_synced_id, last_synced_time FROM sync_state WHERE server_url = ? AND topic = ?"
        let rows = try db.query(sql, bind: { statement in
            try statement.bindText(serverURL, at: 1)
            try statement.bindText(topic, at: 2)
        }, row: { statement -> (id: String?, time: Int) in
            (id: statement.columnText(0), time: statement.columnInt(1) ?? 0)
        })
        return rows.first
    }

    func setSyncedInfo(serverURL: String, topic: String, id: String?, time: Int) throws {
        let sql = """
        INSERT INTO sync_state (server_url, topic, last_synced_id, last_synced_time, last_sync_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(server_url, topic) DO UPDATE SET
            last_synced_id = excluded.last_synced_id,
            last_synced_time = excluded.last_synced_time,
            last_sync_at = excluded.last_sync_at
        """
        let statement = try db.prepare(sql)
        defer { statement.finalize() }
        try statement.bindText(serverURL, at: 1)
        try statement.bindText(topic, at: 2)
        try statement.bindOptionalText(id, at: 3)
        try statement.bindInt(time, at: 4)
        try statement.bindInt(Int(Date().timeIntervalSince1970), at: 5)
        try statement.run()
    }

    // MARK: - Helpers

    /// Case-insensitive substring LIKE pattern with the wildcards in the user text escaped.
    private static func likePattern(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    private enum SQLValue {
        case text(String)
        case int(Int)

        func bind(to statement: SQLiteStatement, at index: Int32) throws {
            switch self {
            case .text(let value): try statement.bindText(value, at: index)
            case .int(let value): try statement.bindInt(value, at: index)
            }
        }
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

    private static func storedMessage(from statement: SQLiteStatement, serverURL: String, topic: String) throws -> StoredMessage {
        let message = NtfyMessage(
            id: statement.columnText(2) ?? "",
            time: statement.columnInt(5) ?? 0,
            event: statement.columnText(4) ?? "message",
            topic: statement.columnText(1) ?? topic,
            message: statement.columnText(6),
            title: statement.columnText(7),
            priority: statement.columnInt(8),
            tags: decodedJSON([String].self, from: statement.columnText(9)),
            click: statement.columnText(10),
            actions: decodedJSON([NtfyMessage.NtfyAction].self, from: statement.columnText(11)),
            attachment: decodedJSON(NtfyMessage.NtfyAttachment.self, from: statement.columnText(12)),
            contentType: statement.columnText(13),
            sequenceId: statement.columnText(3)
        )
        return StoredMessage(
            serverURL: statement.columnText(0) ?? serverURL,
            topic: topic,
            message: message,
            isRead: (statement.columnInt(14) ?? 0) == 1,
            isDeleted: (statement.columnInt(15) ?? 0) == 1,
            rowID: Int64(statement.columnInt(16) ?? 0)
        )
    }
}
