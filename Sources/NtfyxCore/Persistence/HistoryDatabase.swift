import Foundation
import GRDB

/// Builds the single GRDB connection used by `MessageStore` and owns the schema
/// migration chain (`PRAGMA user_version`, audit D1/#2).
enum HistoryDatabase {
    /// Opens (or creates) a database at `path`. `:memory:` yields an in-memory
    /// database (tests); on-disk paths get their parent directory created.
    static func makeQueue(path: String) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            // WAL lets readers (tests/tools) not block the writer; the 5s busy
            // timeout rides out an occasional checkpoint lock.
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA busy_timeout=5000")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
        }

        let queue: DatabaseQueue
        if path == ":memory:" {
            queue = try DatabaseQueue(configuration: configuration)
        } else {
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            queue = try DatabaseQueue(path: path, configuration: configuration)
        }

        try ntfyxMigrator().migrate(queue)
        return queue
    }

    /// The versioned schema chain. Pre-GRDB databases sit at user_version 0:
    /// `v1`'s `CREATE … IF NOT EXISTS` DDL is a no-op on their existing tables,
    /// so the upgrade moves them to user_version 1 without touching any row.
    static func ntfyxMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
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
            )
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_msg_topic_time
            ON messages(server_url, topic, time DESC)
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_msg_unread ON messages(server_url, topic)
            WHERE is_read = 0 AND is_deleted = 0
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_msg_sequence ON messages(server_url, topic, sequence_id)
            WHERE sequence_id IS NOT NULL
            """)
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS sync_state (
                server_url       TEXT NOT NULL,
                topic            TEXT NOT NULL,
                last_synced_id   TEXT,
                last_synced_time INTEGER,
                last_sync_at     INTEGER,
                max_read_time    INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(server_url, topic)
            )
            """)
        }

        return migrator
    }
}
