import XCTest
@testable import NtfyxCore

// MARK: - Mock URLProtocol for watchdog tests

/// Intercepts URLSession requests and returns HTTP 200 without sending any data,
/// simulating a stale connection where the server stops sending keepalives.
final class HoldingURLProtocol: URLProtocol {
    static let requestCountLock = NSLock()
    nonisolated(unsafe) private static var _requestCount = 0
    static var requestCount: Int {
        get { requestCountLock.lock(); defer { requestCountLock.unlock() }; return _requestCount }
        set { requestCountLock.lock(); defer { requestCountLock.unlock() }; _requestCount = newValue }
    }
    nonisolated(unsafe) static var onRequest: ((Int) -> Void)?

    static func reset() {
        requestCount = 0
        onRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let count = HoldingURLProtocol.requestCount + 1
        HoldingURLProtocol.requestCount = count
        HoldingURLProtocol.onRequest?(count)

        // Return HTTP 200 but never send data or finish — simulates stale connection
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Intentionally no didLoad or didFinishLoading — connection stays "open"
    }

    override func stopLoading() {}
}

/// Returns a fixed failure status (e.g. a proxy's 502) with a body, then ends the transfer,
/// so a rejected subscription can be observed end to end. URLSession only forwards the
/// response-decision callback once the protocol has actually produced content.
final class RejectingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requestCount = 0
    static var requestCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return _requestCount }
        set { lock.lock(); _requestCount = newValue; lock.unlock() }
    }
    nonisolated(unsafe) static var statusCode = 502
    nonisolated(unsafe) static var onRequest: (@Sendable (Int) -> Void)?

    static func reset(statusCode: Int) {
        requestCount = 0
        self.statusCode = statusCode
        onRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        RejectingURLProtocol.lock.lock()
        RejectingURLProtocol._requestCount += 1
        let count = RejectingURLProtocol._requestCount
        let status = RejectingURLProtocol.statusCode
        let callback = RejectingURLProtocol.onRequest
        RejectingURLProtocol.lock.unlock()

        callback?(count)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // URLSession only forwards the response decision once the body starts flowing.
        client?.urlProtocol(self, didLoad: Data("gateway unavailable\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Streams a canned NDJSON body and closes, which is what a `since` replay looks like from
/// the server: a burst of cached messages arriving back to back.
final class ReplayURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _lines: [String] = []
    nonisolated(unsafe) private static var _urls: [String] = []

    static func reset(lines: [String]) {
        lock.lock()
        _lines = lines
        _urls = []
        onRequest = nil
        lock.unlock()
    }

    static var requestedURLs: [String] {
        lock.lock(); defer { lock.unlock() }; return _urls
    }

    nonisolated(unsafe) static var onRequest: (@Sendable (Int) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        ReplayURLProtocol.lock.lock()
        ReplayURLProtocol._urls.append(request.url?.absoluteString ?? "")
        let lines = ReplayURLProtocol._lines
        let count = ReplayURLProtocol._urls.count
        let callback = ReplayURLProtocol.onRequest
        ReplayURLProtocol.lock.unlock()

        callback?(count)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !lines.isEmpty {
            client?.urlProtocol(self, didLoad: Data((lines.joined(separator: "\n") + "\n").utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// One ntfy JSON line, as the server writes it to the stream.
private func ndjson(
    id: String, time: Int, topic: String = "t", event: String = "message"
) -> String {
    "{\"id\":\"\(id)\",\"time\":\(time),\"event\":\"\(event)\",\"topic\":\"\(topic)\",\"message\":\"m-\(id)\"}"
}

// MARK: - Event collector

/// Drains a client actor's `events` stream on the main actor and records what it saw.
/// Replaces the old delegate mock: the actor now reports through an `AsyncStream`.
@MainActor
private final class EventCollector {
    private(set) var connectedCount = 0
    private(set) var disconnectedCount = 0
    private(set) var messages: [NtfyMessage] = []
    private(set) var actionEvents: [NtfyMessage] = []
    private(set) var batches: [[NtfyMessage]] = []
    private(set) var failures: [NSError] = []

    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onMessage: ((NtfyMessage) -> Void)?
    var onActionEvent: ((NtfyMessage) -> Void)?
    var onBatch: (([NtfyMessage]) -> Void)?
    var onFailure: ((NSError) -> Void)?

    private var task: Task<Void, Never>?

    func start(for client: NtfyClient) {
        task = Task { [weak self] in
            for await event in client.events {
                guard let self else { return }
                switch event {
                case .connected:
                    self.connectedCount += 1
                    self.onConnected?()
                case .disconnected:
                    self.disconnectedCount += 1
                    self.onDisconnected?()
                case .message(let message):
                    self.messages.append(message)
                    self.onMessage?(message)
                case .actionEvent(let message):
                    self.actionEvents.append(message)
                    self.onActionEvent?(message)
                case .catchUpBatch(let batch):
                    self.batches.append(batch)
                    self.onBatch?(batch)
                case .failure(let error):
                    self.failures.append(error)
                    self.onFailure?(error)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

/// Fulfills an XCTestExpectation at most once, even when the observed event fires on a
/// timer/reconnect loop (e.g. a `.disconnected` event per rejected response). Over-
/// fulfilling while `fulfillment(of:)` is suspended is an XCTest API violation that
/// aborts the async test task with "freed pointer was not the last allocation".
private final class OneShotFulfillment: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fulfill(_ expectation: XCTestExpectation) {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first { expectation.fulfill() }
    }
}

// MARK: - Helper

private func makeSessionConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HoldingURLProtocol.self]
    return config
}

private func makeRejectingSessionConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RejectingURLProtocol.self]
    return config
}

private func makeReplaySessionConfig() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ReplayURLProtocol.self]
    return config
}

// MARK: - Tests

@MainActor
final class NtfyClientTests: XCTestCase {
    // MARK: - URL Construction

    // Actor initializers are nonisolated, so construction assertions stay synchronous.
    func testClientInitialization() {
        let client = NtfyClient(serverURL: "https://ntfy.sh", topics: ["test"])
        XCTAssertEqual(client.serverURL, "https://ntfy.sh")
        XCTAssertEqual(client.topics, ["test"])
    }

    func testClientWithMultipleTopics() {
        let client = NtfyClient(serverURL: "https://ntfy.sh", topics: ["topic1", "topic2", "topic3"])
        XCTAssertEqual(client.topics, ["topic1", "topic2", "topic3"])
    }

    func testClientWithAuthToken() {
        let client = NtfyClient(serverURL: "https://ntfy.sh", topics: ["test"], authToken: "tk_secret123")
        XCTAssertNotNil(client)
    }

    func testClientWithCustomServer() {
        let client = NtfyClient(serverURL: "https://my-ntfy.example.com", topics: ["alerts"])
        XCTAssertNotNil(client)
    }

    // MARK: - Invalid URL

    /// A server URL that can never build a request (e.g. contains a space) must
    /// surface an error instead of hanging in "connecting" forever.
    func testConnectWithInvalidURLReportsErrorAndDisconnects() async {
        let client = NtfyClient(serverURL: "http://exa mple.com", topics: ["test"])
        let collector = EventCollector()

        let errorExp = TrackableExpectation(description: "failure event")
        let disconnectExp = TrackableExpectation(description: "disconnected event")
        var received: NSError?
        collector.onFailure = { error in
            received = error
            errorExp.fulfill()
        }
        collector.onDisconnected = { disconnectExp.fulfill() }
        collector.onConnected = { XCTFail("must not report connect") }

        collector.start(for: client)
        await client.connect()

        await waitForAll([errorExp, disconnectExp], timeout: 2.0)
        collector.stop()

        guard case NtfyClientError.invalidURL(let url)? = received as? NtfyClientError else {
            return XCTFail("expected invalidURL, got \(String(describing: received))")
        }
        XCTAssertEqual(url, "http://exa mple.com")
    }

    // MARK: - Exponential Backoff Calculation

    func testExponentialBackoffCalculation() {
        // Test the exponential backoff formula: min(baseDelay * 2^attempts, maxDelay)
        let baseDelay: TimeInterval = 2.0
        let maxDelay: TimeInterval = 300.0

        // Attempt 0: 2 * 2^0 = 2
        XCTAssertEqual(min(baseDelay * pow(2.0, 0), maxDelay), 2.0)

        // Attempt 1: 2 * 2^1 = 4
        XCTAssertEqual(min(baseDelay * pow(2.0, 1), maxDelay), 4.0)

        // Attempt 2: 2 * 2^2 = 8
        XCTAssertEqual(min(baseDelay * pow(2.0, 2), maxDelay), 8.0)

        // Attempt 3: 2 * 2^3 = 16
        XCTAssertEqual(min(baseDelay * pow(2.0, 3), maxDelay), 16.0)

        // Attempt 4: 2 * 2^4 = 32
        XCTAssertEqual(min(baseDelay * pow(2.0, 4), maxDelay), 32.0)

        // Attempt 5: 2 * 2^5 = 64
        XCTAssertEqual(min(baseDelay * pow(2.0, 5), maxDelay), 64.0)

        // Attempt 6: 2 * 2^6 = 128
        XCTAssertEqual(min(baseDelay * pow(2.0, 6), maxDelay), 128.0)

        // Attempt 7: 2 * 2^7 = 256
        XCTAssertEqual(min(baseDelay * pow(2.0, 7), maxDelay), 256.0)

        // Attempt 8: 2 * 2^8 = 512, capped at 300
        XCTAssertEqual(min(baseDelay * pow(2.0, 8), maxDelay), 300.0)

        // Attempt 9: still capped at 300
        XCTAssertEqual(min(baseDelay * pow(2.0, 9), maxDelay), 300.0)
    }

    func testJitterRange() {
        // Verify jitter calculation stays within ±10%
        let baseDelay: TimeInterval = 100.0

        for _ in 0..<100 {
            let jitter = baseDelay * Double.random(in: -0.1...0.1)
            let delayWithJitter = baseDelay + jitter

            XCTAssertGreaterThanOrEqual(delayWithJitter, 90.0)
            XCTAssertLessThanOrEqual(delayWithJitter, 110.0)
        }
    }

    // MARK: - Disconnect

    func testDisconnectDoesNotCrash() async {
        let client = NtfyClient(serverURL: "https://ntfy.sh", topics: ["test"])
        // Should not crash even if never connected
        await client.disconnect()
    }

    func testMultipleDisconnects() async {
        let client = NtfyClient(serverURL: "https://ntfy.sh", topics: ["test"])
        // Multiple disconnects should be safe
        await client.disconnect()
        await client.disconnect()
        await client.disconnect()
    }

    // MARK: - Watchdog

    func testWatchdogIntervalIsConfigurable() {
        let client = NtfyClient(serverURL: "https://ntfy.sh", topics: ["test"], watchdogInterval: 30.0)
        XCTAssertNotNil(client)
    }

    /// After disconnect(), the watchdog must not fire and trigger a reconnect.
    func testWatchdogDoesNotFireAfterDisconnect() async {
        HoldingURLProtocol.reset()
        let client = NtfyClient(
            serverURL: "https://ntfy.sh", topics: ["test"],
            watchdogInterval: 0.05, baseReconnectDelay: 0.0,
            urlSessionConfiguration: makeSessionConfig()
        )
        let collector = EventCollector()
        collector.start(for: client)

        await client.connect()
        // Cancel before any URL response can be processed by the actor.
        await client.disconnect()

        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(collector.connectedCount, 0, "must not connect after immediate disconnect")
        collector.stop()
    }

    /// Cancelled task errors must not trigger reconnect (avoids double-reconnect when watchdog fires).
    func testCancelledTaskDoesNotTriggerReconnect() async {
        HoldingURLProtocol.reset()

        // Connect, then immediately disconnect — only 1 request should ever be made
        // (no spurious reconnect from the cancelled task's error)
        let initialExp = TrackableExpectation(description: "Initial request received")
        HoldingURLProtocol.onRequest = { count in
            if count >= 1 { initialExp.fulfill() }
        }

        let client = NtfyClient(
            serverURL: "https://ntfy.sh", topics: ["test"],
            watchdogInterval: 60.0, baseReconnectDelay: 0.0,
            urlSessionConfiguration: makeSessionConfig()
        )
        let collector = EventCollector()
        collector.start(for: client)
        await client.connect()
        await waitForAll([initialExp], timeout: 1.0)

        // Disconnect and wait — request count must stay at 1
        await client.disconnect()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(HoldingURLProtocol.requestCount, 1)
        collector.stop()
    }

    /// A server that refuses the subscription (a proxy's 502, a 429 rate limit) used to kill
    /// the connection for good: rejecting the response cancels the task, and that cancellation
    /// is indistinguishable from a deliberate disconnect, so nothing ever retried. Live
    /// messages then stopped arriving and the unread badges only appeared once the user clicked
    /// a topic and the poll pulled the backlog in.
    func testRejectedResponseReconnects() async {
        RejectingURLProtocol.reset(statusCode: 502)

        let retryExp = TrackableExpectation(description: "Second request after the rejected response")
        let retryGate = OneShotFulfillment()
        RejectingURLProtocol.onRequest = { count in
            if count >= 2 { retryGate.fulfill(retryExp) }
        }

        let disconnectExp = TrackableExpectation(description: "Refused server reported as disconnected")
        let disconnectGate = OneShotFulfillment()
        let client = NtfyClient(
            serverURL: "https://ntfy.sh", topics: ["test"],
            watchdogInterval: 60.0, baseReconnectDelay: 0.0,
            urlSessionConfiguration: makeRejectingSessionConfig()
        )
        let collector = EventCollector()
        collector.onDisconnected = { disconnectGate.fulfill(disconnectExp) }
        collector.start(for: client)
        await client.connect()

        await waitForAll([retryExp, disconnectExp], timeout: 5.0)
        await client.disconnect()
        collector.stop()

        XCTAssertGreaterThanOrEqual(RejectingURLProtocol.requestCount, 2)
    }

    // MARK: - Catch-up replay

    private func clearWatermark(_ serverURL: String) {
        UserDefaults.standard.removeObject(
            forKey: NtfyClient.watermarkKey(serverURL: serverURL, fetchMissed: true)
        )
    }

    private func storedWatermark(_ serverURL: String) -> Int {
        UserDefaults.standard.integer(
            forKey: NtfyClient.watermarkKey(serverURL: serverURL, fetchMissed: true)
        )
    }

    /// A server that replays its whole cache used to hand every message over on its own,
    /// which meant tens of thousands of main-thread round-trips (log, banner, database task)
    /// and a frozen UI. The replay now comes in batches.
    func testCatchUpReplayArrivesInBatches() async {
        let serverURL = "https://replay-batch.test"
        clearWatermark(serverURL)
        let now = Int(Date().timeIntervalSince1970)
        let newest = now - 1
        let total = 2000
        ReplayURLProtocol.reset(lines: (0..<total).map { ndjson(id: "m\($0)", time: now - total + $0) })

        let batchExp = TrackableExpectation(description: "replay delivered in batches")
        let closeExp = TrackableExpectation(description: "replay finished")
        var batchSizes: [Int] = []
        var deliveredIndividual = 0
        let collector = EventCollector()
        collector.onBatch = { batch in
            batchSizes.append(batch.count)
            if batchSizes.reduce(0, +) == total { batchExp.fulfill() }
        }
        collector.onMessage = { _ in deliveredIndividual += 1 }
        collector.onDisconnected = { closeExp.fulfill() }

        let client = NtfyClient(
            serverURL: serverURL, topics: ["t"], fetchMissed: true,
            watchdogInterval: 60, baseReconnectDelay: 60,
            urlSessionConfiguration: makeReplaySessionConfig()
        )
        collector.start(for: client)
        await client.connect()

        await waitForAll([batchExp, closeExp], timeout: 10.0)
        await client.disconnect()
        collector.stop()

        XCTAssertEqual(batchSizes.reduce(0, +), total)
        // Two thousand messages used to mean two thousand handovers; now it is one per
        // chunk, and one chunk of that size splits at the batch cap.
        XCTAssertLessThanOrEqual(batchSizes.count, 8, "expected few batches, got \(batchSizes)")
        XCTAssertLessThanOrEqual(batchSizes.max() ?? 0, NtfyClient.maxCatchUpBatchSize)
        XCTAssertEqual(deliveredIndividual, 0)
        XCTAssertTrue(ReplayURLProtocol.requestedURLs.first?.contains("since=all") == true)
        XCTAssertEqual(storedWatermark(serverURL), newest)
    }

    /// Only what the server replays is batched: a message published after we connected still
    /// arrives immediately, so live notifications keep their latency.
    func testLiveMessageBypassesCatchUpBatching() async {
        let serverURL = "https://replay-live.test"
        clearWatermark(serverURL)
        let now = Int(Date().timeIntervalSince1970)
        ReplayURLProtocol.reset(lines: [
            ndjson(id: "old1", time: now - 3),
            ndjson(id: "old2", time: now - 2),
            ndjson(id: "live", time: now + 3600),
        ])

        let liveExp = TrackableExpectation(description: "live message delivered per message")
        var batched: [String] = []
        var live: [String] = []
        let collector = EventCollector()
        collector.onBatch = { batch in batched.append(contentsOf: batch.map(\.id)) }
        collector.onMessage = { message in
            live.append(message.id)
            liveExp.fulfill()
        }

        let client = NtfyClient(
            serverURL: serverURL, topics: ["t"], fetchMissed: true,
            watchdogInterval: 60, baseReconnectDelay: 60,
            urlSessionConfiguration: makeReplaySessionConfig()
        )
        collector.start(for: client)
        await client.connect()

        await waitForAll([liveExp], timeout: 5.0)
        await client.disconnect()
        collector.stop()

        XCTAssertEqual(live, ["live"])
        XCTAssertEqual(batched, ["old1", "old2"])
    }

    /// Adding a subscription must not throw away the progress of the topics that were already
    /// caught up — that reset is what turned "add one topic" into "refetch everything".
    func testSubscriptionChangeKeepsFetchMissedWatermark() async {
        let serverURL = "https://replay-watermark.test"
        let watermark = 1_700_000_000
        UserDefaults.standard.set(
            watermark, forKey: NtfyClient.watermarkKey(serverURL: serverURL, fetchMissed: true)
        )
        ReplayURLProtocol.reset(lines: [])

        func connectOnce(_ topics: [String], expectingRequest count: Int) async {
            let requested = TrackableExpectation(description: "request #\(count)")
            ReplayURLProtocol.onRequest = { seen in
                if seen >= count { requested.fulfill() }
            }
            let client = NtfyClient(
                serverURL: serverURL, topics: topics, fetchMissed: true,
                watchdogInterval: 60, baseReconnectDelay: 60,
                urlSessionConfiguration: makeReplaySessionConfig()
            )
            let collector = EventCollector()
            collector.start(for: client)
            await client.connect()
            await waitForAll([requested], timeout: 2.0)
            await client.disconnect()
            collector.stop()
            ReplayURLProtocol.onRequest = nil
        }

        await connectOnce(["a"], expectingRequest: 1)
        // The config reload after a new topic builds a client for the enlarged topic set.
        await connectOnce(["a", "b"], expectingRequest: 2)

        XCTAssertEqual(ReplayURLProtocol.requestedURLs.count, 2)
        for url in ReplayURLProtocol.requestedURLs {
            XCTAssertTrue(url.contains("since=\(watermark)"), "unexpected replay: \(url)")
        }
        clearWatermark(serverURL)
    }
}
