import Foundation

/// Identifies a (server, topic) pair — the key for unread counts and sync state.
struct TopicRef: Hashable, Sendable, Codable {
    let serverURL: String
    let topic: String

    static func == (lhs: TopicRef, rhs: TopicRef) -> Bool {
        lhs.serverURL == rhs.serverURL && lhs.topic == rhs.topic
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(serverURL)
        hasher.combine(topic)
    }
}

/// Stable, gap-free key for time-ordered pagination (audit 2.3).
/// A whole-second `time` alone is not unique: when a page boundary falls inside a
/// burst that shares one second, a `time < cursor` filter silently drops the rows
/// that were not returned on the previous page. Pairing the timestamp with the
/// row's unique insert order (`rowid_pk`) makes the cursor exact.
struct PageCursor: Equatable, Sendable {
    let time: Int
    let rowID: Int64
}

/// A message row as stored in the local history database.
struct StoredMessage: Identifiable, Sendable {
    let serverURL: String
    let topic: String
    let message: NtfyMessage
    var isRead: Bool
    var isDeleted: Bool
    /// SQLite rowid — the tie-breaker for `PageCursor`, 0 for rows built outside the store.
    var rowID: Int64 = 0

    var id: String { message.id }

    var topicRef: TopicRef {
        TopicRef(serverURL: serverURL, topic: topic)
    }

    /// Sort key used for time-ordered cursors.
    var time: Int { message.time }

    /// Cursor pointing just past this row for the next "load older" page.
    var cursor: PageCursor { PageCursor(time: message.time, rowID: rowID) }
}
