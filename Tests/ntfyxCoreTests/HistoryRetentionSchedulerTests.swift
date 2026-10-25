import XCTest
@testable import NtfyxCore

@MainActor
final class HistoryRetentionSchedulerTests: XCTestCase {
    /// Mutable, Sendable clock the scheduler reads "now" from (only used by the day gate).
    private final class ClockBox: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    /// Builds every collaborator per test with an in-memory store, an isolated
    /// UserDefaults suite and hand-driven fake activities.
    @MainActor
    private final class Harness {
        let store: MessageStore
        let bus = HistoryChangeBus()
        let bag = FakeActivityBag()
        let tasks: BackgroundTasks
        let clock: ClockBox
        let defaults: UserDefaults
        private let suiteName: String

        init(activityIdentifier: String = "test.retention") throws {
            store = try MessageStore.inMemory()
            suiteName = "ntfyx-tests-retention-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            tasks = BackgroundTasks { [bag] in bag.make($0) }
            clock = ClockBox(Date(timeIntervalSince1970: 1_700_000_000))  // 2023-11-14
            self.activityIdentifier = activityIdentifier
        }

        let activityIdentifier: String

        func makeScheduler() -> HistoryRetentionScheduler {
            HistoryRetentionScheduler(
                store: store,
                bus: bus,
                defaults: defaults,
                backgroundTasks: tasks,
                now: { [clock] in clock.now },
                identifier: activityIdentifier
            )
        }

        var fake: FakeSystemActivity? { bag[activityIdentifier] }

        func cleanup() {
            tasks.invalidateAll()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    // MARK: - Helpers

    private func makeMessage(id: String, ageDays: Int) -> NtfyMessage {
        let time = Int(Date().addingTimeInterval(TimeInterval(-ageDays * 86_400)).timeIntervalSince1970)
        return NtfyMessage(
            id: id,
            time: time,
            event: "message",
            topic: "alerts",
            message: "old",
            title: nil,
            priority: 3,
            tags: nil,
            click: nil,
            actions: nil,
            attachment: nil,
            contentType: nil,
            sequenceId: nil
        )
    }

    private func seedExpiredReadMessage(
        in harness: Harness,
        id: String = "old1"
    ) async throws {
        try await harness.store.upsert(makeMessage(id: id, ageDays: 100), serverURL: "https://s.example")
        try await harness.store.markRead(
            true, serverURL: "https://s.example", topic: "alerts", messageID: id
        )
    }

    private func alertsCount(_ harness: Harness) async throws -> Int {
        try await harness.store.messages(serverURL: "https://s.example", topic: "alerts").count
    }

    private func waitFor(
        timeout: TimeInterval = 2,
        condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("条件未在 \(timeout)s 内满足")
    }

    // MARK: - Tests

    func testStartRegistersDailyActivityAndRunsGateImmediately() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        try await seedExpiredReadMessage(in: harness)

        let wildcardChange = TrackableExpectation(description: "retention posts a wildcard bus change")
        let busTask = Task {
            for await change in harness.bus.changes() {
                if change.topicRef == nil {
                    wildcardChange.fulfill()
                    return
                }
            }
        }

        let scheduler = harness.makeScheduler()
        scheduler.start()

        await waitForAll([wildcardChange], timeout: 3)
        busTask.cancel()
        let remaining = try await alertsCount(harness)
        XCTAssertEqual(remaining, 0, "启动即跑应删掉过期已读消息")
        XCTAssertNotNil(harness.defaults.object(forKey: HistoryRetentionScheduler.lastRunDefaultsKey))

        let fake = try XCTUnwrap(harness.fake)
        XCTAssertTrue(fake.repeats)
        XCTAssertEqual(fake.interval, 24 * 60 * 60)
        XCTAssertEqual(fake.tolerance, 6 * 60 * 60)
        XCTAssertEqual(fake.scheduleCount, 1)
    }

    func testSecondRunOnSameDayIsSkipped() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let scheduler = harness.makeScheduler()

        await scheduler.runIfDue()
        let firstStamp = harness.defaults.object(
            forKey: HistoryRetentionScheduler.lastRunDefaultsKey
        ) as? TimeInterval
        XCTAssertNotNil(firstStamp)

        // Planted after the first pass; a same-day rerun must leave it untouched.
        try await seedExpiredReadMessage(in: harness, id: "late1")
        await scheduler.runIfDue()

        let countAfterSkippedSecondRun = try await alertsCount(harness)
        XCTAssertEqual(countAfterSkippedSecondRun, 1)
        XCTAssertEqual(
            harness.defaults.object(forKey: HistoryRetentionScheduler.lastRunDefaultsKey) as? TimeInterval,
            firstStamp,
            "同日跳过不应重写时间戳"
        )
    }

    func testNextDaySystemFireTrimsAgain() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let scheduler = harness.makeScheduler()

        try await seedExpiredReadMessage(in: harness, id: "old1")
        // start() registers the daily activity and runs the gate once immediately.
        scheduler.start()
        try await waitFor { (try? await alertsCount(harness)) == 0 }
        let firstStamp = try XCTUnwrap(
            harness.defaults.object(forKey: HistoryRetentionScheduler.lastRunDefaultsKey) as? TimeInterval
        )

        try await seedExpiredReadMessage(in: harness, id: "old2")

        // Simulate the OS firing the daily activity the next calendar day.
        harness.clock.now = harness.clock.now.addingTimeInterval(26 * 60 * 60)
        try XCTUnwrap(harness.fake).trigger()

        try await waitFor { (try? await alertsCount(harness)) == 0 }
        let secondStamp = try XCTUnwrap(
            harness.defaults.object(forKey: HistoryRetentionScheduler.lastRunDefaultsKey) as? TimeInterval
        )
        XCTAssertGreaterThan(secondStamp, firstStamp)
    }

    func testStopInvalidatesTheDailyActivity() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let scheduler = harness.makeScheduler()

        scheduler.start()
        let fake = try XCTUnwrap(harness.fake)
        try await waitFor {
            harness.defaults.object(forKey: HistoryRetentionScheduler.lastRunDefaultsKey) != nil
        }
        XCTAssertEqual(fake.invalidateCount, 0)

        scheduler.stop()
        XCTAssertEqual(fake.invalidateCount, 1)
    }
}
