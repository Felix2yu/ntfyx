import XCTest
@testable import NtfyxCore

/// Hand-driven replacement for `NSBackgroundActivityScheduler` in tests: records the
/// scheduling parameters and lets tests fire the OS block on demand. No test ever
/// registers a real system activity. The real scheduler's methods are nonisolated, so
/// this fake is too; a lock guards its state.
final class FakeSystemActivity: SystemBackgroundActivityScheduling, @unchecked Sendable {
    var repeats: Bool { get { lock.withLock { box.repeats } } set { lock.withLock { box.repeats = newValue } } }
    var interval: TimeInterval { get { lock.withLock { box.interval } } set { lock.withLock { box.interval = newValue } } }
    var tolerance: TimeInterval { get { lock.withLock { box.tolerance } } set { lock.withLock { box.tolerance = newValue } } }
    var qualityOfService: QualityOfService {
        get { lock.withLock { box.qualityOfService } }
        set { lock.withLock { box.qualityOfService = newValue } }
    }
    var scheduleCount: Int { lock.withLock { box.scheduleCount } }
    var invalidateCount: Int { lock.withLock { box.invalidateCount } }
    var reportedResults: [NSBackgroundActivityScheduler.Result] { lock.withLock { box.results } }

    private final class Box {
        var repeats = false
        var interval: TimeInterval = 0
        var tolerance: TimeInterval = 0
        var qualityOfService: QualityOfService = .default
        var scheduleCount = 0
        var invalidateCount = 0
        var block: (@Sendable (@escaping @Sendable (NSBackgroundActivityScheduler.Result) -> Void) -> Void)?
        var results: [NSBackgroundActivityScheduler.Result] = []
    }

    private let box = Box()
    private let lock = NSLock()

    init(identifier: String) {}

    func schedule(
        _ block: @escaping @Sendable (
            @escaping @Sendable (NSBackgroundActivityScheduler.Result) -> Void
        ) -> Void
    ) {
        lock.withLock {
            box.scheduleCount += 1
            box.block = block
        }
    }

    func invalidate() {
        lock.withLock { box.invalidateCount += 1 }
    }

    /// Simulates one OS fire. Results arrive asynchronously on MainActor; poll
    /// `reportedResults`.
    func trigger() {
        let block: (@Sendable (@escaping @Sendable (NSBackgroundActivityScheduler.Result) -> Void) -> Void)? =
            lock.withLock { box.block }
        block?({ [weak self] result in
            self?.lock.withLock { self?.box.results.append(result) }
        })
    }
}

/// MainActor-owned registry of fake activities, used as the scheduler factory.
@MainActor
final class FakeActivityBag {
    private(set) var byID: [String: FakeSystemActivity] = [:]

    func make(_ identifier: String) -> SystemBackgroundActivityScheduling {
        let fake = FakeSystemActivity(identifier: identifier)
        byID[identifier] = fake
        return fake
    }

    subscript(identifier: String) -> FakeSystemActivity? { byID[identifier] }
}

@MainActor
final class BackgroundTasksTests: XCTestCase {
    private func makeTasks(_ bag: FakeActivityBag) -> BackgroundTasks {
        BackgroundTasks { bag.make($0) }
    }

    private func waitFor(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("条件未在 \(timeout)s 内满足", file: file, line: line)
    }

    func testRegisterConfiguresRepeatingActivity() throws {
        let bag = FakeActivityBag()
        let tasks = makeTasks(bag)

        tasks.register(identifier: "test.activity", interval: 300, tolerance: 45, qualityOfService: .background) {}

        let fake = try XCTUnwrap(bag["test.activity"])
        XCTAssertTrue(fake.repeats)
        XCTAssertEqual(fake.interval, 300)
        XCTAssertEqual(fake.tolerance, 45)
        XCTAssertEqual(fake.qualityOfService, .background)
        XCTAssertEqual(fake.scheduleCount, 1)
    }

    func testRepeatedRegisterInvalidatesPreviousActivity() throws {
        let bag = FakeActivityBag()
        let tasks = makeTasks(bag)

        tasks.register(identifier: "test.activity", interval: 60) {}
        let first = try XCTUnwrap(bag["test.activity"])
        tasks.register(identifier: "test.activity", interval: 120) {}
        let second = try XCTUnwrap(bag["test.activity"])

        XCTAssertEqual(first.invalidateCount, 1, "旧活动必须先 invalidate")
        XCTAssertFalse(second === first, "重注应创建新的 scheduler")
        XCTAssertEqual(second.interval, 120)
        XCTAssertEqual(second.invalidateCount, 0)
    }

    func testUnregisterInvalidatesAndForgets() async throws {
        let bag = FakeActivityBag()
        let tasks = makeTasks(bag)
        var workRuns = 0

        tasks.register(identifier: "test.activity", interval: 60) { workRuns += 1 }
        let fake = try XCTUnwrap(bag["test.activity"])
        tasks.unregister(identifier: "test.activity")
        XCTAssertEqual(fake.invalidateCount, 1)

        // A late OS callback after unregister must neither run the work nor hang the
        // scheduler: completion still has to be signalled.
        fake.trigger()
        try await waitFor { !fake.reportedResults.isEmpty }
        XCTAssertEqual(workRuns, 0)
        XCTAssertEqual(fake.reportedResults, [.finished])

        // Unregistering again is a no-op.
        tasks.unregister(identifier: "test.activity")
        XCTAssertEqual(fake.invalidateCount, 1)
    }

    func testInvalidateAllStopsEveryActivity() throws {
        let bag = FakeActivityBag()
        let tasks = makeTasks(bag)

        tasks.register(identifier: "test.a", interval: 60) {}
        tasks.register(identifier: "test.b", interval: 60) {}
        tasks.invalidateAll()

        XCTAssertEqual(bag["test.a"]?.invalidateCount, 1)
        XCTAssertEqual(bag["test.b"]?.invalidateCount, 1)
    }

    func testFireRunsWorkOnMainActorAndSignalsFinished() async throws {
        let bag = FakeActivityBag()
        let tasks = makeTasks(bag)
        actor Order {
            var entries: [String] = []
            func append(_ entry: String) { entries.append(entry) }
        }
        let order = Order()

        tasks.register(identifier: "test.activity", interval: 60) {
            // The completion handler cannot have fired before the work body runs.
            await order.append("work")
        }
        let fake = try XCTUnwrap(bag["test.activity"])
        fake.trigger()

        try await waitFor { !fake.reportedResults.isEmpty }
        XCTAssertEqual(fake.reportedResults, [.finished])
        let entries = await order.entries
        XCTAssertEqual(entries, ["work"])
    }
}
