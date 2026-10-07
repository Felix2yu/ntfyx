import XCTest
@testable import ntfyx

/// The menu bar badge used to stay at zero after launch (it only refreshed when the next
/// live message arrived) and to go stale after marking messages read in the history window.
/// UnreadBadgeSync fixes both ends; these tests cover the seed-on-start and the
/// notification-driven refresh against a real in-memory store.
@MainActor
final class UnreadBadgeSyncTests: XCTestCase {

    private func makeMessage(id: String) -> NtfyMessage {
        NtfyMessage(
            id: id, time: 1_700_000_000, event: "message", topic: "alerts",
            message: "body", title: nil, priority: 3, tags: nil,
            click: nil, actions: nil, attachment: nil, contentType: nil, sequenceId: nil
        )
    }

    func testStartSeedsBadgeFromExistingUnreads() async throws {
        let store = try MessageStore.inMemory()
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m2"), serverURL: "https://s.example")

        let recorder = BadgeRecorder()
        let sync = UnreadBadgeSync(store: store) { recorder.append($0) }
        sync.start()
        defer { sync.stop() }

        try await waitUntil { recorder.last == 2 }
    }

    func testBadgeFollowsStoreChangeNotifications() async throws {
        let store = try MessageStore.inMemory()
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")

        let recorder = BadgeRecorder()
        let sync = UnreadBadgeSync(store: store) { recorder.append($0) }
        sync.start()
        defer { sync.stop() }
        try await waitUntil { recorder.last == 1 }

        try await store.markRead(true, serverURL: "https://s.example", topic: "alerts", messageID: "m1")
        NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)

        try await waitUntil { recorder.last == 0 }
    }

    /// A burst of store changes — one per replayed chunk, one per live message — has to settle
    /// into a single badge pass. Recomputing the aggregate per notification made a replay
    /// re-read the whole table hundreds of times for one visible digit.
    func testStoreChangeBurstSettlesIntoOneRefresh() async throws {
        let store = try MessageStore.inMemory()
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m2"), serverURL: "https://s.example")

        let recorder = BadgeRecorder()
        let sync = UnreadBadgeSync(store: store) { recorder.append($0) }
        sync.start()
        defer { sync.stop() }
        try await waitUntil { recorder.last == 2 }
        let passesAfterSeed = recorder.counts.count

        try await store.markRead(true, serverURL: "https://s.example", topic: "alerts", messageID: "m1")
        for _ in 0..<10 {
            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
        }
        try await waitUntil { recorder.last == 1 }
        try await Task.sleep(nanoseconds: 500_000_000)  // let a straggler timer fire, if any

        XCTAssertEqual(recorder.counts.count, passesAfterSeed + 1)
    }

    func testStopIgnoresLaterChanges() async throws {
        let store = try MessageStore.inMemory()
        try await store.upsert(makeMessage(id: "m1"), serverURL: "https://s.example")

        let recorder = BadgeRecorder()
        let sync = UnreadBadgeSync(store: store) { recorder.append($0) }
        sync.start()
        try await waitUntil { recorder.last == 1 }
        sync.stop()

        try await store.markRead(true, serverURL: "https://s.example", topic: "alerts", messageID: "m1")
        NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(recorder.last, 1)
    }

    private func waitUntil(timeoutSeconds: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met before timeout")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

@MainActor
private final class BadgeRecorder {
    private(set) var counts: [Int] = []
    var last: Int? { counts.last }
    func append(_ count: Int) { counts.append(count) }
}
