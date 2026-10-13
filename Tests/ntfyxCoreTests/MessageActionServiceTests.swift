import XCTest
@testable import NtfyxCore

/// Records every request an API call made and answers with a canned status/body, so the
/// batching, chunking and /v1/topics behavior can be pinned without a server.
final class RecordingURLProtocol: URLProtocol {
    struct Call: Equatable {
        let method: String
        let path: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _calls: [Call] = []
    nonisolated(unsafe) private static var _status = 200
    nonisolated(unsafe) private static var _body = "{}"

    static var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    static var paths: [String] { calls.map(\.path) }
    static var getPaths: [String] { calls.filter { $0.method == "GET" }.map(\.path) }
    static var deletePaths: [String] { calls.filter { $0.method == "DELETE" }.map(\.path) }

    static func reset(status: Int = 200, body: String = "{}") {
        lock.lock(); _calls = []; _status = status; _body = body; lock.unlock()
    }

    /// Fresh session with the recorder installed; also clears the recorded calls.
    static func session(status: Int = 200, body: String = "{}") -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        reset(status: status, body: body)
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._calls.append(
            Call(
                method: request.httpMethod ?? "GET",
                path: request.url?.path ?? ""
            )
        )
        let status = Self._status
        let body = Self._body
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self, didLoad: body.data(using: .utf8) ?? Data()
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class MessageActionServiceTests: XCTestCase {

    private func target(_ id: String, sequence: String? = nil) -> (sequenceID: String?, messageID: String) {
        (sequence, id)
    }

    // MARK: - Batched mark-read

    /// One request per message meant a 500-unread topic cost 500 round trips; the fork
    /// accepts a comma-separated id list, so a topic now takes a handful of requests.
    func testMarkAllReadBatchesIDsIntoOneRequest() async {
        let session = RecordingURLProtocol.session()

        let synced = await MessageActionService.markAllReadOnServer(
            serverURL: "https://s.example", topic: "alpha",
            targets: (0..<3).map { target("msg\($0)") },
            authToken: nil, session: session
        )

        XCTAssertEqual(synced, 3)
        XCTAssertEqual(RecordingURLProtocol.getPaths, ["/alpha/msg0,msg1,msg2/read"])
    }

    func testMarkAllReadChunksAtTheServerLimit() async {
        let session = RecordingURLProtocol.session()
        let count = MessageActionService.sequenceIDsPerRequest + 10

        let synced = await MessageActionService.markAllReadOnServer(
            serverURL: "https://s.example", topic: "alpha",
            targets: (0..<count).map { target("msg\($0)") },
            authToken: nil, session: session
        )

        XCTAssertEqual(synced, count)
        let paths = RecordingURLProtocol.getPaths
        XCTAssertEqual(paths.count, 2)
        let chunks = paths.map { $0.trimmingPrefix("/alpha/").dropLast("/read".count) }
        XCTAssertEqual(chunks[0].split(separator: ",").count, MessageActionService.sequenceIDsPerRequest)
        XCTAssertEqual(chunks[1].split(separator: ",").count, 10)
        XCTAssertTrue(chunks[1].hasPrefix("msg\(MessageActionService.sequenceIDsPerRequest),"))
    }

    func testMarkAllReadPrefersSequenceIDAndDeduplicates() async {
        let session = RecordingURLProtocol.session()

        let synced = await MessageActionService.markAllReadOnServer(
            serverURL: "https://s.example", topic: "alpha",
            targets: [
                target("id1", sequence: "seq-1"),
                target("id2", sequence: "seq-1"),   // same target through another row
                target("id3"),
            ],
            authToken: nil, session: session
        )

        XCTAssertEqual(synced, 2)
        XCTAssertEqual(RecordingURLProtocol.getPaths, ["/alpha/seq-1,id3/read"])
    }

    /// The server rejects the whole list if one id is outside its charset, so an odd id is
    /// dropped instead of poisoning the batch.
    func testMarkAllReadDropsIDsTheServerCannotAccept() async {
        let session = RecordingURLProtocol.session()

        let synced = await MessageActionService.markAllReadOnServer(
            serverURL: "https://s.example", topic: "alpha",
            targets: [target("fine1"), target("bad id"), target("", sequence: ""), target("中文")],
            authToken: nil, session: session
        )

        XCTAssertEqual(synced, 1)
        XCTAssertEqual(RecordingURLProtocol.getPaths, ["/alpha/fine1/read"])
    }

    func testMarkAllReadStopsAtFirstRejectedChunk() async {
        let session = RecordingURLProtocol.session(status: 403)
        let count = MessageActionService.sequenceIDsPerRequest + 5

        let synced = await MessageActionService.markAllReadOnServer(
            serverURL: "https://s.example", topic: "alpha",
            targets: (0..<count).map { target("msg\($0)") },
            authToken: nil, session: session
        )

        XCTAssertEqual(synced, 0)
        XCTAssertEqual(RecordingURLProtocol.calls.count, 1)  // no point pushing on
    }

    func testMarkReadOnServerStillAcceptsAlreadyGoneTargets() async {
        let session = RecordingURLProtocol.session(status: 404)

        let ok = await MessageActionService.markReadOnServer(
            serverURL: "https://s.example", topic: "alpha",
            sequenceID: nil, messageID: "msg1",
            authToken: "tok", session: session
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(RecordingURLProtocol.getPaths, ["/alpha/msg1/read"])
    }

    // MARK: - Server-side clear (delete has no batch route)

    func testDeleteAllOnServerSendsOneRequestPerTarget() async {
        let session = RecordingURLProtocol.session()

        let synced = await MessageActionService.deleteAllOnServer(
            serverURL: "https://s.example", topic: "alpha",
            targets: [target("id1", sequence: "seq-1"), target("id2")],
            authToken: nil, session: session
        )

        XCTAssertEqual(synced, 2)
        XCTAssertEqual(RecordingURLProtocol.deletePaths, ["/alpha/seq-1", "/alpha/id2"])
    }

    func testDeleteAllOnServerStopsAtFirstRejection() async {
        let session = RecordingURLProtocol.session(status: 403)

        let synced = await MessageActionService.deleteAllOnServer(
            serverURL: "https://s.example", topic: "alpha",
            targets: (0..<5).map { target("msg\($0)") },
            authToken: nil, session: session
        )

        XCTAssertEqual(synced, 0)
        XCTAssertEqual(RecordingURLProtocol.calls.count, 1)
    }

    // MARK: - Topic lifecycle

    func testFetchServerTopicsDecodesTheTopicList() async throws {
        let session = RecordingURLProtocol.session(body: #"{"topics":["alerts","releases"]}"#)

        let topics = try await MessageActionService.fetchServerTopics(
            serverURL: "https://s.example", authToken: "tok", session: session
        )

        XCTAssertEqual(topics, ["alerts", "releases"])
        XCTAssertEqual(RecordingURLProtocol.getPaths, ["/v1/topics"])
    }

    func testFetchServerTopicsReportsRejection() async {
        let session = RecordingURLProtocol.session(status: 403)

        do {
            _ = try await MessageActionService.fetchServerTopics(
                serverURL: "https://s.example", authToken: nil, session: session
            )
            XCTFail("expected the rejected listing to throw")
        } catch let error as TopicActionError {
            XCTAssertEqual(error, .httpStatus(403))
        } catch {
            XCTFail("expected a TopicActionError, got \(error)")
        }
    }

    func testRetireTopicCallsTheServerRouteAndReportsPurgeCount() async throws {
        let session = RecordingURLProtocol.session(body: #"{"topic":"alpha","deleted_messages":7}"#)

        let deleted = try await MessageActionService.retireTopic(
            serverURL: "https://s.example", topic: "alpha",
            authToken: "tok", session: session
        )

        XCTAssertEqual(deleted, 7)
        XCTAssertEqual(RecordingURLProtocol.deletePaths, ["/v1/topics/alpha"])
    }
}
