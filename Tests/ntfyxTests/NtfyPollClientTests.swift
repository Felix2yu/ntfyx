import XCTest
@testable import ntfyx

/// Streams a canned NDJSON poll body. A full-history sync can carry tens of thousands of
/// events, and one write transaction per event is what made it crawl, so the client has to
/// hand them over in chunks — this protocol is how the chunking is observed.
private final class PollBodyProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _lines: [String] = []

    static func reset(lines: [String]) {
        lock.lock(); _lines = lines; lock.unlock()
    }

    static var lines: [String] {
        lock.lock(); defer { lock.unlock() }; return _lines
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = PollBodyProtocol.lines
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: Data(body.joined(separator: "\n").utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Batches as the poll client handed them over. A box because the callback is `@Sendable`,
/// and the callback runs on the session's serial queue.
private final class BatchBox: @unchecked Sendable {
    var batches: [[NtfyMessage]] = []
    var sizes: [Int] { batches.map(\.count) }
    var ids: [String] { batches.flatMap { $0.map(\.id) } }
}

/// Counts how many times the session configuration factory runs.
private final class Counter: @unchecked Sendable {
    var value = 0
}

/// One ntfy JSON line, as the server writes it to the stream.
private func pollLine(
    id: String, time: Int, topic: String = "alerts", event: String = "message"
) -> String {
    "{\"id\":\"\(id)\",\"time\":\(time),\"event\":\"\(event)\",\"topic\":\"\(topic)\",\"message\":\"m-\(id)\"}"
}

final class NtfyPollClientTests: XCTestCase {

    private func withMockedPolling(
        lines: [String], counter: Counter? = nil, _ body: () async throws -> Void
    ) async rethrows {
        let production = NtfyPollClient.configuration
        NtfyPollClient.configuration = {
            counter?.value += 1
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [PollBodyProtocol.self]
            return config
        }
        // The session is built lazily from the configuration, so both ends of the swap need
        // to drop it: otherwise a mocked session leaks into the suites that poll for real.
        NtfyPollClient.resetSession()
        PollBodyProtocol.reset(lines: lines)
        defer {
            NtfyPollClient.resetSession()
            NtfyPollClient.configuration = production
            PollBodyProtocol.reset(lines: [])
        }
        try await body()
    }

    func testEventsArriveInBatchesOfTheConfiguredSize() async throws {
        let total = NtfyPollClient.eventBatchSize * 2 + 50
        let box = BatchBox()

        try await withMockedPolling(
            lines: (0..<total).map { pollLine(id: "m\($0)", time: 1_700_000_000 + $0) }
        ) {
            let result = try await NtfyPollClient.poll(
                serverURL: "https://ntfy.example.com", topic: "alerts",
                since: "all", authToken: nil
            ) { batch in
                box.batches.append(batch)
            }

            XCTAssertEqual(result.messageCount, total)
            XCTAssertEqual(result.newestMessage?.time, 1_700_000_000 + total - 1)
        }

        XCTAssertEqual(box.sizes, [200, 200, 50])
        XCTAssertEqual(box.ids.count, total)
        XCTAssertEqual(box.ids.first, "m0")
        XCTAssertEqual(box.ids.last, "m\(total - 1)")
    }

    /// Delete and clear events ride along in message order, so an event still arrives after
    /// the message it targets and the store applies the removal to a row that exists.
    func testActionEventsShareTheBatchWithTheirPredecessors() async throws {
        let box = BatchBox()

        try await withMockedPolling(
            lines: [
                pollLine(id: "m1", time: 1_700_000_000),
                pollLine(id: "evt1", time: 1_700_000_001, event: NtfyMessage.deleteEvent),
                pollLine(id: "m2", time: 1_700_000_002),
                pollLine(id: "evt2", time: 1_700_000_003, event: NtfyMessage.clearEvent),
            ]
        ) {
            let result = try await NtfyPollClient.poll(
                serverURL: "https://ntfy.example.com", topic: "alerts",
                since: "all", authToken: nil
            ) { batch in
                box.batches.append(batch)
            }

            XCTAssertEqual(result.messageCount, 2)
            XCTAssertEqual(result.actionEventCount, 2)
        }

        XCTAssertEqual(box.sizes, [4])
        XCTAssertEqual(box.ids, ["m1", "evt1", "m2", "evt2"])
    }

    /// A session carries a connection pool, so building one per poll meant every topic opened
    /// in the history window paid its own handshake. Two polls, one configuration call.
    func testPollsReuseOneSession() async throws {
        let builds = Counter()

        try await withMockedPolling(
            lines: [pollLine(id: "m1", time: 1_700_000_000)], counter: builds
        ) {
            for _ in 0..<2 {
                let result = try await NtfyPollClient.poll(
                    serverURL: "https://ntfy.example.com", topic: "alerts",
                    since: "all", authToken: nil
                ) { _ in }
                XCTAssertEqual(result.messageCount, 1)
            }
        }

        XCTAssertEqual(builds.value, 1)
    }
}
