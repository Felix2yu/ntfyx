import XCTest
import GRDB
@testable import NtfyxCore

/// FTS5 trigram search via a single route (column-level LIKE over messages_fts),
/// literal metacharacter handling, performance, and the v1→v2 migration.
final class MessageStoreFTSTests: XCTestCase {
    private var store: MessageStore!

    override func setUpWithError() throws {
        store = try MessageStore.inMemory()
    }

    override func tearDownWithError() throws {
        store = nil
    }

    private func makeMessage(
        id: String,
        topic: String = "alerts",
        time: Int = 1_700_000_000,
        title: String? = nil,
        message: String? = nil
    ) -> NtfyMessage {
        NtfyMessage(
            id: id, time: time, event: "message", topic: topic,
            message: message, title: title, priority: nil, tags: nil,
            click: nil, actions: nil, attachment: nil, contentType: nil,
            sequenceId: nil
        )
    }

    // MARK: - Single-route semantics (column-level LIKE over messages_fts)

    /// One- and two-character terms have no trigram windows, so they cannot seek the
    /// index — but they must still match exactly via the virtual-table LIKE filter.
    func testOneAndTwoCharacterTermsStayExact() async throws {
        try await store.upsert(
            makeMessage(id: "m1", title: "告警标题文字", message: "磁盘 ab 余量"),
            serverURL: "https://s.example"
        )

        let cjk = try await store.searchAll(query: "告警").map { $0.message.id }
        XCTAssertEqual(cjk, ["m1"])
        let latin = try await store.searchAll(query: "ab").map { $0.message.id }
        XCTAssertEqual(latin, ["m1"])
        // Single CJK ideograph.
        let ideograph = try await store.searchAll(query: "磁").map { $0.message.id }
        XCTAssertEqual(ideograph, ["m1"])
        // No false positives for absent short terms.
        let absentLatin = try await store.searchAll(query: "xy")
        XCTAssertTrue(absentLatin.isEmpty)
        let absentCJK = try await store.searchAll(query: "晴")
        XCTAssertTrue(absentCJK.isEmpty)
    }

    /// Punctuation-only windows and exact symbols must behave like plain substring
    /// matching: `100%` must not hit `100x`, an underscore is a literal underscore,
    /// and a backslash is a literal backslash.
    func testPunctuationAndLikeMetacharactersAreLiteral() async throws {
        try await store.upsert(
            makeMessage(id: "percent", title: "100% done", message: "进度 100x 完成"),
            serverURL: "https://s.example"
        )
        try await store.upsert(
            makeMessage(id: "underscore", topic: "build_jobs", title: "zzz", message: "yyy"),
            serverURL: "https://s.example"
        )
        try await store.upsert(
            makeMessage(id: "underscoreLookalike", topic: "buildxjobs", title: "qqq", message: "www"),
            serverURL: "https://s.example"
        )
        try await store.upsert(
            makeMessage(id: "backslash", title: "路径 C:\\Temp 目录", message: "rrr"),
            serverURL: "https://s.example"
        )

        // `%` must not act as a wildcard: matches "100% done", not "100x".
        let percentHits = try await store.searchAll(query: "100%").map { $0.message.id }
        XCTAssertEqual(percentHits, ["percent"])
        // `_` must not match a single arbitrary character.
        let underscoreHits = try await store.searchAll(query: "build_jobs").map { $0.message.id }
        XCTAssertEqual(underscoreHits, ["underscore"])
        // Literal backslash content is searchable (escaping must not corrupt it).
        let backslashHits = try await store.searchAll(query: #"C:\Temp"#).map { $0.message.id }
        XCTAssertEqual(backslashHits, ["backslash"])
        // Dotted/punctuated versions still match only the literal occurrence.
        let dotted = try await store.searchAll(query: "v2.1.1")
        XCTAssertTrue(dotted.isEmpty)
        let plainHits = try await store.searchAll(query: "100x").map { $0.message.id }
        XCTAssertEqual(plainHits, ["percent"])
    }

    /// EXPLAIN QUERY PLAN pins the routing: a query without LIKE metacharacters must be
    /// served by per-column trigram index seeks (never a `messages` base-table scan),
    /// while a query requiring ESCAPE scans the FTS virtual table itself.
    func testExplainQueryPlanPinsTrigramRouting() async throws {
        let (fileStore, path, directory) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await fileStore.upsert(
            makeMessage(id: "m1", title: "zephyrmarker", message: "x"),
            serverURL: "https://s.example"
        )
        let reader = try DatabaseQueue(path: path)
        defer { try? reader.close() }

        func plan(for query: String) throws -> String {
            // Build the exact production filter, then run its inner predicate against
            // EXPLAIN QUERY PLAN (the fragment is shaped for the outer `messages` query).
            let columns = ["title", "message", "topic"]
            let filter = MessageStore.ftsTextFilter(columns: columns, query: query)
            let comparator = filter.sql.contains("ESCAPE") ? "LIKE ? ESCAPE '\\'" : "LIKE ?"
            let whereClause = columns.map { "\($0) \(comparator)" }.joined(separator: " OR ")
            return try reader.inDatabase { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "EXPLAIN QUERY PLAN SELECT rowid FROM messages_fts WHERE \(whereClause)",
                    arguments: [filter.pattern, filter.pattern, filter.pattern]
                )
                return rows.map { ($0["detail"] as String?) ?? "" }.joined(separator: " | ")
            }
        }

        let accelerated = try plan(for: "zephyrmarker")
        XCTAssertTrue(
            accelerated.contains("MULTI-INDEX OR") && accelerated.contains("messages_fts"),
            "≥3-char metacharacter-free query expected per-column trigram index seeks, got: \(accelerated)"
        )
        XCTAssertFalse(
            accelerated.contains(" SCAN messages "),
            "search must never scan the base messages table: \(accelerated)"
        )

        let escaped = try plan(for: "100%")
        XCTAssertTrue(
            escaped.contains("messages_fts") && !escaped.contains(" SCAN messages "),
            "ESCAPE variant scans the FTS table, not the base table: \(escaped)"
        )
    }

    // MARK: - FTS hits (Chinese + English, all three columns)

    func testChineseSubstringMatchViaFTS() async throws {
        try await store.upsert(
            makeMessage(id: "m1", title: "系统通知中心", message: "备份任务已顺利完成"),
            serverURL: "https://s.example"
        )
        try await store.upsert(
            makeMessage(id: "m2", title: "天气", message: "今天天气晴转多云"),
            serverURL: "https://s.example"
        )

        let rows = try await store.messages(
            serverURL: "https://s.example", topic: "alerts", searchText: "通知中心"
        )
        XCTAssertEqual(rows.map { $0.message.id }, ["m1"])

        let inner = try await store.messages(
            serverURL: "https://s.example", topic: "alerts", searchText: "份任务已"
        )
        XCTAssertEqual(inner.map { $0.message.id }, ["m1"])

        let none = try await store.messages(
            serverURL: "https://s.example", topic: "alerts", searchText: "通知告警"
        )
        XCTAssertTrue(none.isEmpty)
    }

    func testEnglishCaseInsensitiveAndInnerSubstring() async throws {
        try await store.upsert(
            makeMessage(id: "m1", title: "Deploy FAILED", message: "Container restarted"),
            serverURL: "https://s.example"
        )

        let lower = try await store.searchAll(query: "deploy")
        XCTAssertEqual(lower.map { $0.message.id }, ["m1"])

        let inner = try await store.searchAll(query: "iled")
        XCTAssertEqual(inner.map { $0.message.id }, ["m1"])
    }

    func testFTSMatchesTitleBodyAndTopicColumns() async throws {
        try await store.upsert(
            makeMessage(id: "m1", topic: "container-monitor", title: "zzz", message: "zzz"),
            serverURL: "https://s.example"
        )
        try await store.upsert(
            makeMessage(id: "m2", topic: "other", title: "告警标题文字", message: "yyy"),
            serverURL: "https://s.example"
        )
        try await store.upsert(
            makeMessage(id: "m3", topic: "other2", title: "qqq", message: "正文监控内容abc"),
            serverURL: "https://s.example"
        )

        // topic column
        let byTopic = try await store.searchAll(query: "monitor")
        XCTAssertEqual(byTopic.map { $0.message.id }, ["m1"])
        // title column (CJK substring)
        let byTitle = try await store.searchAll(query: "警标题文")
        XCTAssertEqual(byTitle.map { $0.message.id }, ["m2"])
        // body column
        let byBody = try await store.searchAll(query: "文监控内")
        XCTAssertEqual(byBody.map { $0.message.id }, ["m3"])
    }

    func testShortPunctuationAndEmojiQueriesDoNotCrash() async throws {
        try await store.upsert(
            makeMessage(id: "m1", title: "100% done", message: "进度 100x 完成 🎉"),
            serverURL: "https://s.example"
        )

        let percent = try await store.searchAll(query: "100%")
        XCTAssertEqual(percent.map { $0.message.id }, ["m1"])
        let mixed = try await store.searchAll(query: "100y 完") // no such substring
        XCTAssertTrue(mixed.isEmpty)
        // Sanity: the present cross-space substring IS found.
        let present = try await store.searchAll(query: "100x 完")
        XCTAssertEqual(present.map { $0.message.id }, ["m1"])
        let emoji = try await store.searchAll(query: "🎉🎉🎉")
        XCTAssertTrue(emoji.isEmpty)
        // Bare quotes are ordinary characters on this single route and must not throw.
        let quotes = try await store.searchAll(query: "\"\"\"")
        XCTAssertTrue(quotes.isEmpty)
        // 2-character terms still match as exact substrings.
        let short = try await store.searchAll(query: "完成")
        XCTAssertEqual(short.map { $0.message.id }, ["m1"])
    }

    // MARK: - Trigger sync on physical delete

    func testPhysicalDeleteRemovesFTSIndexEntry() async throws {
        let (fileStore, path, directory) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await fileStore.upsert(
            makeMessage(id: "m1", title: "删除目标通知", message: "x"),
            serverURL: "https://s.example"
        )
        try await fileStore.upsert(
            makeMessage(id: "keep", topic: "other", title: "保留通知", message: "x"),
            serverURL: "https://s.example"
        )
        let beforeDelete = try await fileStore.searchAll(query: "删除目标")
        XCTAssertEqual(beforeDelete.map { $0.message.id }, ["m1"])
        XCTAssertEqual(try scalar(at: path, sql: "SELECT COUNT(*) FROM messages_fts"), 2)

        // deleteTopic physically removes rows → AFTER DELETE trigger must prune FTS.
        try await fileStore.deleteTopic(serverURL: "https://s.example", topic: "alerts")

        let deletedHits = try await fileStore.searchAll(query: "删除目标")
        XCTAssertTrue(deletedHits.isEmpty)
        let keptHits = try await fileStore.searchAll(query: "保留通知")
        XCTAssertEqual(keptHits.map { $0.message.id }, ["keep"])

        // Direct index inspection: exactly one FTS row remains (ghost external-content
        // rows would never surface in a join, so the raw count is the real check).
        XCTAssertEqual(try scalar(at: path, sql: "SELECT COUNT(*) FROM messages_fts"), 1)
    }

    // MARK: - v1 → v2 migration on a legacy on-disk database

    func testV2MigrationBackfillsExistingRowsAndSyncsTriggers() async throws {
        let path = try legacyV1DatabasePath()
        defer {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: path).deletingLastPathComponent()
            )
        }

        // Opening through the store runs v1 (IF NOT EXISTS no-op) then v2:
        // virtual table + triggers + 'rebuild' backfill.
        let migrated = try MessageStore(dbPath: path)

        // Pre-existing rows are searchable via the rebuilt trigram index.
        let old = try await migrated.searchAll(query: "通知中心")
        XCTAssertEqual(old.map { $0.message.id }, ["legacy-1"])
        let oldInTopic = try await migrated.messages(
            serverURL: "https://legacy.example", topic: "alerts", searchText: "备份任务"
        )
        XCTAssertEqual(oldInTopic.map { $0.message.id }, ["legacy-2"])

        // AFTER INSERT trigger: rows arriving after migration are indexed.
        try await migrated.upsert(
            makeMessage(id: "new-1", topic: "fresh", title: "迁移后的新通知", message: "b"),
            serverURL: "https://legacy.example"
        )
        let newHits = try await migrated.searchAll(query: "后的新通")
        XCTAssertEqual(newHits.map { $0.message.id }, ["new-1"])

        // AFTER DELETE trigger keeps the index in sync on a real v2 library.
        try await migrated.deleteTopic(serverURL: "https://legacy.example", topic: "alerts")
        let oldTitleHits = try await migrated.searchAll(query: "通知中心")
        XCTAssertTrue(oldTitleHits.isEmpty)
        let oldBodyHits = try await migrated.searchAll(query: "备份任务")
        XCTAssertTrue(oldBodyHits.isEmpty)

        // grdb_migrations records v1 and v2.
        let migrations = try scalar(
            at: path,
            sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier IN ('v1','v2')"
        )
        XCTAssertEqual(migrations, 2)

        // Reopen: v2 must not run again (no 'trigger already exists' failure).
        let reopened = try MessageStore(dbPath: path)
        let afterReopen = try await reopened.searchAll(query: "后的新通")
        XCTAssertEqual(afterReopen.map { $0.message.id }, ["new-1"])
    }

    /// Builds a database that looks exactly like a pre-GRDB / v1 library: business
    /// tables present and populated, no FTS, no grdb_migrations.
    private func legacyV1DatabasePath() throws -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ntfyx-fts-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("legacy.db").path

        let queue = try DatabaseQueue(path: path)
        try queue.inDatabase { db in
            try db.execute(sql: """
            CREATE TABLE messages (
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
            )
            """)
            try db.execute(
                sql: """
                INSERT INTO messages (server_url, topic, msg_id, event, time, title, message)
                VALUES (?, ?, ?, 'message', ?, ?, ?)
                """,
                arguments: StatementArguments(
                    [
                        "https://legacy.example", "alerts", "legacy-1",
                        1_700_000_000, "系统通知中心", "旧库第一条"
                    ] as [DatabaseValueConvertible?]
                )
            )
            try db.execute(
                sql: """
                INSERT INTO messages (server_url, topic, msg_id, event, time, title, message)
                VALUES (?, ?, ?, 'message', ?, ?, ?)
                """,
                arguments: StatementArguments(
                    [
                        "https://legacy.example", "alerts", "legacy-2",
                        1_700_000_001, "旧标题", "备份任务完成报告"
                    ] as [DatabaseValueConvertible?]
                )
            )
        }
        try queue.close()
        return path
    }

    // MARK: - Performance: FTS must beat a LIKE table scan

    func testTrigramColumnLikeIsAtLeastThreeTimesFasterThanTableScan() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ntfyx-fts-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("perf.db").path

        let perfStore = try MessageStore(dbPath: path)
        let total = 12_000
        let markerEvery = 1_000
        var events: [NtfyMessage] = []
        events.reserveCapacity(total)
        for i in 0..<total {
            let isMarker = i % markerEvery == 0
            let body = isMarker
                ? "zephyrmarker 特殊标记正文内容 \(i)"
                : PerformanceFiller.body(index: i)
            events.append(
                NtfyMessage(
                    id: "p\(i)", time: 1_700_000_000 + i, event: "message",
                    topic: isMarker ? "marker-topic" : "bulk",
                    message: body,
                    title: isMarker ? "zephyrmarker 标题 \(i)" : PerformanceFiller.title(index: i),
                    priority: nil, tags: nil, click: nil, actions: nil,
                    attachment: nil, contentType: nil, sequenceId: nil
                )
            )
        }
        _ = try await perfStore.applyBatch(events, serverURL: "https://perf.example")

        // Warm up both paths.
        _ = try await perfStore.searchAll(query: "zephyrmarker")
        let reader = try DatabaseQueue(path: path)
        defer { try? reader.close() }
        let likePattern = "%zephyrmarker%"
        let likeSQL = """
        SELECT msg_id FROM messages
        WHERE is_deleted = 0
          AND (title LIKE ? ESCAPE '\\' OR message LIKE ? ESCAPE '\\' OR topic LIKE ? ESCAPE '\\')
        """
        func likeBindings() -> StatementArguments {
            StatementArguments([likePattern, likePattern, likePattern] as [String])
        }
        try reader.inDatabase { db in
            _ = try Row.fetchAll(db, sql: likeSQL, arguments: likeBindings())
        }

        // Result sets must be equivalent.
        let ftsIDs = Set(try await perfStore.searchAll(query: "zephyrmarker").map { $0.message.id })
        let likeIDs = try reader.inDatabase { db -> Set<String> in
            let rows = try Row.fetchAll(db, sql: likeSQL, arguments: likeBindings())
            return Set(rows.compactMap { $0["msg_id"] as String? })
        }
        XCTAssertEqual(ftsIDs, likeIDs)
        XCTAssertEqual(ftsIDs.count, total / markerEvery)

        let iterations = 9
        var ftsTimes: [Double] = []
        var likeTimes: [Double] = []
        ftsTimes.reserveCapacity(iterations)
        likeTimes.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let ftsStart = Date()
            _ = try await perfStore.searchAll(query: "zephyrmarker")
            ftsTimes.append(Date().timeIntervalSince(ftsStart))

            let likeStart = Date()
            try reader.inDatabase { db in
                _ = try Row.fetchAll(db, sql: likeSQL, arguments: likeBindings())
            }
            likeTimes.append(Date().timeIntervalSince(likeStart))
        }

        let trigramMedian = ftsTimes.sorted()[iterations / 2]
        let scanMedian = likeTimes.sorted()[iterations / 2]
        print("Trigram median: \(trigramMedian * 1000)ms, table-scan median: \(scanMedian * 1000)ms, ratio: \(scanMedian / max(trigramMedian, 0.00001))x")
        XCTAssertLessThan(
            trigramMedian, scanMedian / 3,
            "trigram column LIKE should be at least 3x faster than a base-table LIKE scan on 12k rows"
        )
    }

    // MARK: - File-database helpers

    private func makeFileStore() throws -> (MessageStore, String, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ntfyx-fts-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("history.db").path
        return (try MessageStore(dbPath: path), path, directory)
    }

    /// Opens a second (read) connection against a file database so the tests can
    /// inspect FTS internals — an external-content ghost row never surfaces via a
    /// join, so `SELECT COUNT(*) FROM messages_fts` is the real trigger check.
    private func scalar(at path: String, sql: String) throws -> Int {
        let queue = try DatabaseQueue(path: path)
        defer { try? queue.close() }
        return try queue.inDatabase { try Int.fetchOne($0, sql: sql) ?? 0 }
    }
}

/// Deterministic Chinese/English filler text generator (no randomness, so the
/// performance test is reproducible).
private enum PerformanceFiller {
    static let characters = Array(
        "消息正文内容服务器告警备份容器监控发布下载任务天气生日提醒健康检查站点运行状态日志轮询事件处理计划总结报告磁盘网络证书更新重启编排调度历史记录搜索性能索引测试数据填充"
    )

    static func body(index: Int) -> String {
        var state = UInt64(index &+ 1) &* 6_364_136_223_846_793_005 &+ 1
        var output = ""
        output.reserveCapacity(320)
        while output.count < 300 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let pick = characters[Int((state >> 33) % UInt64(characters.count))]
            output.append(pick)
        }
        return output
    }

    static func title(index: Int) -> String {
        "常规通知编号\(index % 9000)"
    }
}
