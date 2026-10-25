import XCTest
@testable import NtfyxCore

/// Tiny locked box so @Sendable source callbacks can record what they saw.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// E2b: cloud changes are observed, not polled. The observer's sources are injected, so
/// these tests never touch a real NSMetadataQuery or kqueue except one smoke test.
@MainActor
final class CloudChangeObserverTests: XCTestCase {
    nonisolated(unsafe) private var collected: Task<Void, Never>?
    private var events: [CloudChange] = []
    private var expectation: TrackableExpectation?

    private func collect(from observer: CloudChangeObserver, count: Int) {
        let exp = TrackableExpectation(description: "received \(count) event(s)")
        if count <= 1 {
            exp.assertForOverFulfill = true
        }
        expectation = exp
        collected = Task { @MainActor [weak self] in
            var received = 0
            for await event in observer.changes {
                guard let self else { return }
                self.events.append(event)
                received += 1
                if received >= count { self.expectation?.fulfill() }
            }
        }
    }

    override func tearDown() {
        collected?.cancel()
        collected = nil
        super.tearDown()
    }

    // MARK: - Observer coalescing and source selection

    func testBurstCoalescesIntoOneDebouncedEvent() async throws {
        let primary = FakeSource(startResult: true)
        let observer = makeObserver(isICloud: true, debounce: 0.1, primary: primary, fallback: FakeSource(startResult: true))
        collect(from: observer, count: 1)
        observer.start()
        XCTAssertTrue(primary.started)

        primary.fire()
        try await Task.sleep(nanoseconds: 40_000_000)
        primary.fire()
        try await Task.sleep(nanoseconds: 40_000_000)
        primary.fire()

        await waitForAll([expectation!], timeout: 2)
        // Wait long enough that a non-coalesced second event would have arrived.
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(events.count, 1)
        observer.stop()
    }

    func testEventCarriesConflictURLs() async throws {
        let conflict = URL(fileURLWithPath: "/tmp/config (conflict).yml")
        let primary = FakeSource(startResult: true)
        let observer = CloudChangeObserver(
            rootDirectory: "/tmp", isICloud: true, debounceInterval: 0.05,
            conflictURLs: { [conflict] },
            makePrimary: { primary },
            makeFallback: { FakeSource(startResult: true) }
        )
        collect(from: observer, count: 1)
        observer.start()
        primary.fire()

        await waitForAll([expectation!], timeout: 2)
        XCTAssertEqual(events.first?.conflictURLs, [conflict])
        observer.stop()
    }

    func testICloudFallsBackWhenMetadataQueryCannotStart() async {
        let primary = FakeSource(startResult: false)
        let fallback = FakeSource(startResult: true)
        let observer = makeObserver(isICloud: true, debounce: 0.05, primary: primary, fallback: fallback)
        observer.start()
        XCTAssertTrue(primary.started)
        XCTAssertTrue(primary.stopped, "查询启动失败后必须立刻释放")
        XCTAssertTrue(fallback.started, "降级为目录事件源")
        observer.stop()
        XCTAssertTrue(fallback.stopped)
    }

    func testCustomFolderUsesTheDispatchSourceDirectly() {
        let primary = FakeSource(startResult: true)
        let fallback = FakeSource(startResult: true)
        let observer = makeObserver(isICloud: false, debounce: 0.05, primary: primary, fallback: fallback)
        observer.start()
        XCTAssertFalse(primary.started, "自定义目录不需要 NSMetadataQuery")
        XCTAssertTrue(fallback.started)
        observer.stop()
    }

    func testNoSourceMeansNoEventsAndNoCrash() async throws {
        let observer = makeObserver(isICloud: true, debounce: 0.05,
                                    primary: FakeSource(startResult: false),
                                    fallback: FakeSource(startResult: false))
        let task = Task { for await _ in observer.changes {
            XCTFail("没有任何事件源，不应产生事件")
        } }
        observer.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        observer.stop()
        task.cancel()
    }

    func testStopHaltsFurtherEvents() async throws {
        let primary = FakeSource(startResult: true)
        let observer = makeObserver(isICloud: true, debounce: 0.05, primary: primary, fallback: FakeSource(startResult: true))
        observer.start()
        observer.stop()
        primary.fire()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(primary.stopped)
    }

    private func makeObserver(
        isICloud: Bool, debounce: TimeInterval,
        primary: FakeSource, fallback: FakeSource
    ) -> CloudChangeObserver {
        CloudChangeObserver(
            rootDirectory: "/tmp", isICloud: isICloud, debounceInterval: debounce,
            conflictURLs: { [] },
            makePrimary: { primary },
            makeFallback: { fallback }
        )
    }

    // MARK: - Fakes

    final class FakeSource: CloudChangeObserver.Source, @unchecked Sendable {
        let startResult: Bool
        var started = false
        var stopped = false
        private var onEvent: (@Sendable () -> Void)?

        init(startResult: Bool) { self.startResult = startResult }

        func start(onEvent: @escaping @Sendable () -> Void) -> Bool {
            started = true
            self.onEvent = onEvent
            return startResult
        }
        func stop() { stopped = true }
        func fire() { onEvent?() }
    }
}

// MARK: - MetadataQueryCloudSource

@MainActor
final class MetadataQueryCloudSourceTests: XCTestCase {
    private final class FakeQuery: NSObject, MetadataQuerying {
        var searchScopes: [Any] = []
        var predicate: NSPredicate?
        var startResult: Bool
        var resultURLs: [URL]
        var started = false
        var stopped = false
        var updatesEnabled = true

        init(startResult: Bool = true, resultURLs: [URL] = []) {
            self.startResult = startResult
            self.resultURLs = resultURLs
        }

        func startQuery() -> Bool { started = true; return startResult }
        func stopQuery() { stopped = true }
        func disableUpdates() { updatesEnabled = false }
        func enableUpdates() { updatesEnabled = true }
    }

    func testNotDownloadedPlaceholderKicksOffDownloadAndWaitsForNextUpdate() async {
        let center = NotificationCenter()
        let query = FakeQuery(resultURLs: [URL(fileURLWithPath: "/tmp/config.yml")])
        let readinesses = Box<[CloudFileReadiness]>([.needsDownload, .ready])
        let downloadsStarted = Box(0)
        let fired = Box(0)
        let eventExpectation = TrackableExpectation(description: "merge event after download completes")

        let source = MetadataQueryCloudSource(
            directoryURL: URL(fileURLWithPath: "/tmp"),
            fileName: "config.yml",
            notificationCenter: center,
            makeQuery: { query },
            readiness: { _ in
                readinesses.value.isEmpty ? .ready : readinesses.value.removeFirst()
            },
            startDownload: { _ in downloadsStarted.value += 1 }
        )

        let started = source.start(onEvent: {
            fired.value += 1
            eventExpectation.fulfill()
        })
        XCTAssertTrue(started)
        XCTAssertTrue(query.started)
        XCTAssertEqual(query.searchScopes.first as? URL, URL(fileURLWithPath: "/tmp"))
        XCTAssertNotNil(query.predicate)

        center.post(name: Notification.Name.NSMetadataQueryDidFinishGathering, object: query)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(downloadsStarted.value, 1, "未下载的占位文件应触发拉取，而不是合并")
        XCTAssertEqual(fired.value, 0)

        center.post(name: Notification.Name.NSMetadataQueryDidUpdate, object: query)
        await waitForAll([eventExpectation], timeout: 2)
        XCTAssertEqual(fired.value, 1)
        source.stop()
        XCTAssertTrue(query.stopped)
    }

    func testFailedQueryStartReturnsFalseAndGoesQuiet() async {
        let center = NotificationCenter()
        let query = FakeQuery(startResult: false)
        let readinessChecks = Box(0)
        let source = MetadataQueryCloudSource(
            directoryURL: URL(fileURLWithPath: "/tmp"),
            fileName: "config.yml",
            notificationCenter: center,
            makeQuery: { query },
            readiness: { _ in readinessChecks.value += 1; return .ready }
        )

        XCTAssertFalse(source.start(onEvent: {}))
        XCTAssertTrue(query.stopped, "失败的查询必须停止")
        center.post(name: Notification.Name.NSMetadataQueryDidFinishGathering, object: query)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(readinessChecks.value, 0, "观察者注销后不应再有回调")
    }

    func testQueryWithoutResultsStaysQuiet() async {
        let center = NotificationCenter()
        let query = FakeQuery(resultURLs: [])
        let readinessChecks = Box(0)
        let fired = Box(0)
        let source = MetadataQueryCloudSource(
            directoryURL: URL(fileURLWithPath: "/tmp"),
            fileName: "config.yml",
            notificationCenter: center,
            makeQuery: { query },
            readiness: { _ in readinessChecks.value += 1; return .ready }
        )
        _ = source.start(onEvent: { fired.value += 1 })
        center.post(name: Notification.Name.NSMetadataQueryDidFinishGathering, object: query)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(readinessChecks.value, 0)
        XCTAssertEqual(fired.value, 0)
        source.stop()
    }
}

// MARK: - DispatchSourceCloudSource

@MainActor
final class DispatchSourceCloudSourceTests: XCTestCase {
    private final class FakeFileSystemSource: FileSystemEventSourcing, @unchecked Sendable {
        var handler: (() -> Void)?
        var cancelHandler: (() -> Void)?
        var resumed = false
        var cancelled = false

        func install(handler: @escaping @Sendable () -> Void) { self.handler = handler }
        func installCancelHandler(_ handler: @escaping @Sendable () -> Void) { cancelHandler = handler }
        func resume() { resumed = true }
        func cancel() { cancelled = true; cancelHandler?() }
        func trigger() { handler?() }
    }

    func testOpenFailureReturnsFalse() {
        let source = DispatchSourceCloudSource(
            directoryURL: URL(fileURLWithPath: "/tmp"),
            makeSource: { _ in XCTFail("打开失败时不该建 source"); return nil },
            openDirectory: { _ in -1 }
        )
        XCTAssertFalse(source.start(onEvent: {}))
    }

    func testEventsFlowAndStopCancelsTheSourceAndClosesFD() async {
        let fake = FakeFileSystemSource()
        let eventExpectation = TrackableExpectation(description: "directory event")
        let fdToClose = Box<CInt>(-99)
        let source = DispatchSourceCloudSource(
            directoryURL: URL(fileURLWithPath: "/tmp"),
            makeSource: { fd in fdToClose.value = fd; return fake },
            openDirectory: { _ in Darwin.open("/tmp", O_EVTONLY) }
        )
        XCTAssertTrue(source.start(onEvent: { eventExpectation.fulfill() }))
        XCTAssertTrue(fake.resumed)
        fake.trigger()
        await waitForAll([eventExpectation], timeout: 2)

        source.stop()
        XCTAssertTrue(fake.cancelled)
        // The cancel handler closed the descriptor: a second close fails with EBADF.
        XCTAssertEqual(Darwin.close(fdToClose.value), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testSourceFactoryFailureClosesTheDescriptor() {
        let opened = Box<CInt>(-1)
        let source = DispatchSourceCloudSource(
            directoryURL: URL(fileURLWithPath: "/tmp"),
            makeSource: { fd in opened.value = fd; return nil },
            openDirectory: { _ in Darwin.open("/tmp", O_EVTONLY) }
        )
        XCTAssertFalse(source.start(onEvent: {}))
        XCTAssertGreaterThanOrEqual(opened.value, 0)
        XCTAssertEqual(Darwin.close(opened.value), -1, "描述符应已在内部关闭")
        XCTAssertEqual(errno, EBADF)
    }

    func testRealDirectorySourceSmokeTest() async throws {
        // One real kqueue against a temp directory: writes must surface as events.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ntfyx-observer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let eventExpectation = TrackableExpectation(description: "real directory event")
        eventExpectation.assertForOverFulfill = false  // one atomic write fans out into several kqueue events
        let source = DispatchSourceCloudSource(directoryURL: directory)
        XCTAssertTrue(source.start(onEvent: { eventExpectation.fulfill() }))
        defer { source.stop() }

        try "x".write(to: directory.appendingPathComponent("ping.txt"), atomically: true, encoding: .utf8)
        await waitForAll([eventExpectation], timeout: 3)
    }
}
