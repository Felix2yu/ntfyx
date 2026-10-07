import XCTest
@testable import ntfyx

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

// MARK: - Mock delegate

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

final class MockNtfyDelegate: NtfyClientDelegate {
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onMessage: ((NtfyMessage) -> Void)?
    var onActionEvent: ((NtfyMessage) -> Void)?
    var onCatchUpBatch: (([NtfyMessage]) -> Void)?

    func ntfyClientDidConnect(_ client: NtfyClient) { onConnect?() }
    func ntfyClientDidDisconnect(_ client: NtfyClient) { onDisconnect?() }
    func ntfyClient(_ client: NtfyClient, didEncounterError error: Error) { onError?(error) }
    func ntfyClient(_ client: NtfyClient, didReceiveMessage message: NtfyMessage) { onMessage?(message) }
    func ntfyClient(_ client: NtfyClient, didReceiveActionEvent event: NtfyMessage) { onActionEvent?(event) }
    func ntfyClient(_ client: NtfyClient, didReceiveCatchUpBatch batch: [NtfyMessage]) { onCatchUpBatch?(batch) }
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

final class NtfyClientTests: XCTestCase {
    // MARK: - URL Construction

    func testClientInitialization() {
        let client = NtfyClient(serverURL: "https://ntfy.sh", topics: ["test"])
        XCTAssertNotNil(client)
    }

    func testClientWithMultipleTopics() {
        let client = NtfyClient(serverURL: "https://ntfy.sh", topics: ["topic1", "topic2", "topic3"])
        XCTAssertNotNil(client)
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
    func testConnectWithInvalidURLReportsErrorAndDisconnects() {
        let client = NtfyClient(serverURL: "http://exa mple.com", topics: ["test"])
        let delegate = MockNtfyDelegate()
        client.delegate = delegate

        let errorExp = expectation(description: "didEncounterError")
        let disconnectExp = expectation(description: "didDisconnect")
        var received: Error?
        delegate.onError = { error in
            received = error
            errorExp.fulfill()
        }
        delegate.onDisconnect = { disconnectExp.fulfill() }
        delegate.onConnect = { XCTFail("must not report connect") }

        client.connect()

        wait(for: [errorExp, disconnectExp], timeout: 2.0)
        let ntfyError = received as? NtfyError
        guard case NtfyError.serverInvalidURL(let url)? = ntfyError else {
            return XCTFail("expected serverInvalidURL, got \(String(describing: received))")
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

    func testDisconnectDoesNotCrash() {
        let client = NtfyClient(serverURL: "https://ntfy.sh", topics: ["test"])
        // Should not crash even if never connected
        client.disconnect()
    }

    func testMultipleDisconnects() {
        let client = NtfyClient(serverURL: "https://ntfy.sh", topics: ["test"])
        // Multiple disconnects should be safe
        client.disconnect()
        client.disconnect()
        client.disconnect()
    }

    // MARK: - Watchdog

    func testWatchdogIntervalIsConfigurable() {
        let client = NtfyClient(serverURL: "https://ntfy.sh", topics: ["test"], watchdogInterval: 30.0)
        XCTAssertNotNil(client)
    }

    /// After disconnect(), the watchdog must not fire and trigger a reconnect.
    @MainActor func testWatchdogDoesNotFireAfterDisconnect() {
        HoldingURLProtocol.reset()
        let connectExp = expectation(description: "No reconnect after disconnect")
        connectExp.isInverted = true

        let delegate = MockNtfyDelegate()
        delegate.onConnect = { connectExp.fulfill() }

        let client = NtfyClient(
            serverURL: "https://ntfy.sh", topics: ["test"],
            watchdogInterval: 0.05, baseReconnectDelay: 0.0,
            urlSessionConfiguration: makeSessionConfig()
        )
        client.delegate = delegate
        client.connect()
        client.disconnect()  // Immediately cancel — watchdog must not trigger

        waitForExpectations(timeout: 0.3)
    }

/// Cancelled task errors must not trigger reconnect (avoids double-reconnect when watchdog fires).
    @MainActor func testCancelledTaskDoesNotTriggerReconnect() {
        HoldingURLProtocol.reset()

        // Connect, then immediately disconnect — only 1 request should ever be made
        // (no spurious reconnect from the cancelled task's error)
        let initialExp = expectation(description: "Initial request received")
        HoldingURLProtocol.onRequest = { count in
            if count >= 1 { initialExp.fulfill() }
        }

        let client = NtfyClient(
            serverURL: "https://ntfy.sh", topics: ["test"],
            watchdogInterval: 60.0, baseReconnectDelay: 0.0,
            urlSessionConfiguration: makeSessionConfig()
        )
        client.connect()
        waitForExpectations(timeout: 1.0)

        // Disconnect and wait — request count must stay at 1
        client.disconnect()
        let noExtraExp = expectation(description: "No extra reconnect request")
        noExtraExp.isInverted = true
        HoldingURLProtocol.onRequest = { count in
            if count >= 2 { noExtraExp.fulfill() }
        }
        waitForExpectations(timeout: 0.3)

        XCTAssertEqual(HoldingURLProtocol.requestCount, 1)
    }

    /// A server that refuses the subscription (a proxy's 502, a 429 rate limit) used to kill
    /// the connection for good: rejecting the response cancels the task, and that cancellation
    /// is indistinguishable from a deliberate disconnect, so nothing ever retried. Live
    /// messages then stopped arriving and the unread badges only appeared once the user clicked
    /// a topic and the poll pulled the backlog in.
    ///
    /// Not @MainActor: the client reports and reschedules on the main queue, which only drains
    /// while this test blocks off-thread waiting for the expectations.
    func testRejectedResponseReconnects() {
        RejectingURLProtocol.reset(statusCode: 502)

        let retryExp = expectation(description: "Second request after the rejected response")
        RejectingURLProtocol.onRequest = { count in
            if count >= 2 { retryExp.fulfill() }
        }

        let disconnectExp = expectation(description: "Refused server reported as disconnected")
        let delegate = MockNtfyDelegate()
        delegate.onDisconnect = { disconnectExp.fulfill() }

        let client = NtfyClient(
            serverURL: "https://ntfy.sh", topics: ["test"],
            watchdogInterval: 60.0, baseReconnectDelay: 0.0,
            urlSessionConfiguration: makeRejectingSessionConfig()
        )
        client.delegate = delegate
        client.connect()

        wait(for: [retryExp, disconnectExp], timeout: 5.0)
        client.disconnect()

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
    func testCatchUpReplayArrivesInBatches() {
        let serverURL = "https://replay-batch.test"
        clearWatermark(serverURL)
        let now = Int(Date().timeIntervalSince1970)
        let newest = now - 1
        let total = 2000
        ReplayURLProtocol.reset(lines: (0..<total).map { ndjson(id: "m\($0)", time: now - total + $0) })

        let batchExp = expectation(description: "replay delivered in batches")
        let closeExp = expectation(description: "replay finished")
        var batchSizes: [Int] = []
        var deliveredIndividual = 0
        let delegate = MockNtfyDelegate()
        delegate.onCatchUpBatch = { batch in
            batchSizes.append(batch.count)
            if batchSizes.reduce(0, +) == total { batchExp.fulfill() }
        }
        delegate.onMessage = { _ in deliveredIndividual += 1 }
        delegate.onDisconnect = { closeExp.fulfill() }

        let client = NtfyClient(
            serverURL: serverURL, topics: ["t"], fetchMissed: true,
            watchdogInterval: 60, baseReconnectDelay: 60,
            urlSessionConfiguration: makeReplaySessionConfig()
        )
        client.delegate = delegate
        client.connect()

        wait(for: [batchExp, closeExp], timeout: 10.0)
        client.disconnect()

        XCTAssertEqual(batchSizes.reduce(0, +), total)
        // Two thousand messages used to mean two thousand main-thread handovers; now it is
        // one per chunk, and one chunk of that size splits at the batch cap.
        XCTAssertLessThanOrEqual(batchSizes.count, 8, "expected few batches, got \(batchSizes)")
        XCTAssertLessThanOrEqual(batchSizes.max() ?? 0, NtfyClient.maxCatchUpBatchSize)
        XCTAssertEqual(deliveredIndividual, 0)
        XCTAssertTrue(ReplayURLProtocol.requestedURLs.first?.contains("since=all") == true)
        XCTAssertEqual(storedWatermark(serverURL), newest)
    }

    /// Only what the server replays is batched: a message published after we connected still
    /// reaches the delegate immediately, so live notifications keep their latency.
    func testLiveMessageBypassesCatchUpBatching() {
        let serverURL = "https://replay-live.test"
        clearWatermark(serverURL)
        let now = Int(Date().timeIntervalSince1970)
        ReplayURLProtocol.reset(lines: [
            ndjson(id: "old1", time: now - 3),
            ndjson(id: "old2", time: now - 2),
            ndjson(id: "live", time: now + 3600),
        ])

        let liveExp = expectation(description: "live message delivered per message")
        var batched: [String] = []
        var live: [String] = []
        let delegate = MockNtfyDelegate()
        delegate.onCatchUpBatch = { batch in batched.append(contentsOf: batch.map(\.id)) }
        delegate.onMessage = { message in
            live.append(message.id)
            liveExp.fulfill()
        }

        let client = NtfyClient(
            serverURL: serverURL, topics: ["t"], fetchMissed: true,
            watchdogInterval: 60, baseReconnectDelay: 60,
            urlSessionConfiguration: makeReplaySessionConfig()
        )
        client.delegate = delegate
        client.connect()

        wait(for: [liveExp], timeout: 5.0)
        client.disconnect()

        XCTAssertEqual(live, ["live"])
        XCTAssertEqual(batched, ["old1", "old2"])
    }

    /// Adding a subscription must not throw away the progress of the topics that were already
    /// caught up — that reset is what turned "add one topic" into "refetch everything".
    func testSubscriptionChangeKeepsFetchMissedWatermark() {
        let serverURL = "https://replay-watermark.test"
        let watermark = 1_700_000_000
        UserDefaults.standard.set(
            watermark, forKey: NtfyClient.watermarkKey(serverURL: serverURL, fetchMissed: true)
        )
        ReplayURLProtocol.reset(lines: [])

        func connectOnce(_ topics: [String], expectingRequest count: Int) {
            let requested = expectation(description: "request #\(count)")
            ReplayURLProtocol.onRequest = { seen in
                if seen >= count { requested.fulfill() }
            }
            let client = NtfyClient(
                serverURL: serverURL, topics: topics, fetchMissed: true,
                watchdogInterval: 60, baseReconnectDelay: 60,
                urlSessionConfiguration: makeReplaySessionConfig()
            )
            client.connect()
            wait(for: [requested], timeout: 2.0)
            client.disconnect()
            ReplayURLProtocol.onRequest = nil
        }

        connectOnce(["a"], expectingRequest: 1)
        // The config reload after a new topic builds a client for the enlarged topic set.
        connectOnce(["a", "b"], expectingRequest: 2)

        XCTAssertEqual(ReplayURLProtocol.requestedURLs.count, 2)
        for url in ReplayURLProtocol.requestedURLs {
            XCTAssertTrue(url.contains("since=\(watermark)"), "unexpected replay: \(url)")
        }
        clearWatermark(serverURL)
    }

    /// Builds before the key stopped carrying the topic list stored the watermark under one
    /// key per topic set, so after an upgrade the current key starts empty and the first
    /// connect replays `since=all`. The newest legacy value has to be carried over — and the
    /// legacy keys dropped, so the scan happens once rather than on every launch.
    func testLegacyTopicScopedWatermarkIsCarriedOver() {
        let serverURL = "https://replay-legacy-watermark.test"
        let legacyKey = "lastMessageTime-\(serverURL)-t,u"
        let currentKey = NtfyClient.watermarkKey(serverURL: serverURL, fetchMissed: true)
        UserDefaults.standard.removeObject(forKey: currentKey)
        UserDefaults.standard.set(1_700_000_000, forKey: legacyKey)
        ReplayURLProtocol.reset(lines: [])

        let requested = expectation(description: "connect request")
        ReplayURLProtocol.onRequest = { _ in requested.fulfill() }
        let client = NtfyClient(
            serverURL: serverURL, topics: ["t", "u"], fetchMissed: true,
            watchdogInterval: 60, baseReconnectDelay: 60,
            urlSessionConfiguration: makeReplaySessionConfig()
        )
        client.connect()
        wait(for: [requested], timeout: 2.0)
        client.disconnect()
        ReplayURLProtocol.onRequest = nil

        XCTAssertTrue(
            ReplayURLProtocol.requestedURLs.contains { $0.contains("since=1700000000") },
            "expected the migrated watermark, got \(ReplayURLProtocol.requestedURLs)"
        )
        XCTAssertEqual(UserDefaults.standard.integer(forKey: currentKey), 1_700_000_000)
        XCTAssertNil(UserDefaults.standard.object(forKey: legacyKey))

        UserDefaults.standard.removeObject(forKey: currentKey)
    }
}
