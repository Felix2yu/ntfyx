import XCTest
import Network
@testable import NtfyxCore

/// Records intercepted attachment-download requests and answers with a fixed
/// status/body, so auth-header and caching behavior can be asserted without a server.
/// (Internal, not private: HistoryViewModelTests reuses it for the retry-state test.)
final class AttachmentMockProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [URLRequest] = []
    nonisolated(unsafe) private static var _status = 200
    nonisolated(unsafe) private static var _body = Data()

    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    static func reset(status: Int, body: Data) {
        lock.lock(); _requests = []; _status = status; _body = body; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        AttachmentMockProtocol.lock.lock()
        AttachmentMockProtocol._requests.append(request)
        let status = AttachmentMockProtocol._status
        let body = AttachmentMockProtocol._body
        AttachmentMockProtocol.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func attachmentMockSession(status: Int, body: Data) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AttachmentMockProtocol.self]
    AttachmentMockProtocol.reset(status: status, body: body)
    return URLSession(configuration: config)
}

/// Audit 3.5: attachments download through the app (with the server's auth token
/// for same-host URLs), are cached, and open with the default application.
final class AttachmentServiceTests: XCTestCase {
    private var cacheDir: URL!

    override func setUpWithError() throws {
        cacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("attachment-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheDir)
    }

    private func makeAttachment(name: String = "report.pdf", url: String) -> NtfyMessage.NtfyAttachment {
        NtfyMessage.NtfyAttachment(name: name, url: url, type: "application/pdf", size: 4, expires: nil)
    }

    func testSameHostDownloadSendsBearerToken() async throws {
        let body = Data("PDF!".utf8)
        let session = attachmentMockSession(status: 200, body: body)

        let fileURL = try await AttachmentService.download(
            attachment: makeAttachment(url: "https://ntfy.example/secret/file/report.pdf"),
            serverURL: "https://ntfy.example",
            authToken: "tk-123",
            to: cacheDir,
            session: session
        )

        XCTAssertEqual(AttachmentMockProtocol.requests.count, 1)
        XCTAssertEqual(AttachmentMockProtocol.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tk-123")
        XCTAssertEqual(try Data(contentsOf: fileURL), body)
        // Hash-prefixed, sanitized name keeps distinct messages from colliding.
        XCTAssertTrue(fileURL.lastPathComponent.contains("report"))
        XCTAssertTrue(fileURL.lastPathComponent.hasSuffix(".pdf"))
    }

    func testCrossHostAttachmentGetsNoToken() async throws {
        let session = attachmentMockSession(status: 200, body: Data("x".utf8))

        _ = try await AttachmentService.download(
            attachment: makeAttachment(url: "https://evil-cdn.example/report.pdf"),
            serverURL: "https://ntfy.example",
            authToken: "tk-123",
            to: cacheDir,
            session: session
        )

        XCTAssertNil(AttachmentMockProtocol.requests[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testCachedFileIsReusedWithoutSecondRequest() async throws {
        let url = "https://ntfy.example/file/abc"
        _ = try await AttachmentService.download(
            attachment: makeAttachment(name: "a.txt", url: url),
            serverURL: "https://ntfy.example",
            authToken: nil,
            to: cacheDir,
            session: attachmentMockSession(status: 200, body: Data("first".utf8))
        )
        let session2 = attachmentMockSession(status: 200, body: Data("second".utf8))

        let fileURL = try await AttachmentService.download(
            attachment: makeAttachment(name: "a.txt", url: url),
            serverURL: "https://ntfy.example",
            authToken: nil,
            to: cacheDir,
            session: session2
        )

        XCTAssertTrue(AttachmentMockProtocol.requests.isEmpty)
        XCTAssertEqual(String(data: try Data(contentsOf: fileURL), encoding: .utf8), "first")
    }

    func testHTTPErrorThrowsAndWritesNothing() async throws {
        let session = attachmentMockSession(status: 404, body: Data())
        do {
            _ = try await AttachmentService.download(
                attachment: makeAttachment(url: "https://ntfy.example/gone.pdf"),
                serverURL: "https://ntfy.example",
                authToken: nil,
                to: cacheDir,
                session: session
            )
            XCTFail("expected http error")
        } catch let error as AttachmentService.AttachmentError {
            XCTAssertEqual(error, .http(status: 404))
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        XCTAssertTrue(contents.isEmpty)
    }

    func testInvalidURLThrows() async throws {
        do {
            _ = try await AttachmentService.download(
                attachment: makeAttachment(url: ""),
                serverURL: "https://ntfy.example",
                authToken: nil,
                to: cacheDir,
                session: attachmentMockSession(status: 200, body: Data())
            )
            XCTFail("expected invalidURL")
        } catch let error as AttachmentService.AttachmentError {
            XCTAssertEqual(error, .invalidURL)
        }
    }

    func testUnsafeFileNameIsSanitizedButExtensionKept() async throws {
        let session = attachmentMockSession(status: 200, body: Data("ok".utf8))
        let fileURL = try await AttachmentService.download(
            attachment: makeAttachment(name: "../../武 器/泄露.txt", url: "https://ntfy.example/f"),
            serverURL: "https://ntfy.example",
            authToken: nil,
            to: cacheDir,
            session: session
        )
        let name = fileURL.lastPathComponent
        XCTAssertTrue(name.hasSuffix(".txt"), name)
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(".."))
    }

    // MARK: - PR8: streaming to a temp file + atomic move

    func testChunkedStreamLandsIntactWithNoTempResidue() async throws {
        let chunks = [
            Data(repeating: 0x41, count: 40_000),
            Data(repeating: 0x42, count: 40_000), // crosses the 64 KB flush boundary
            Data(repeating: 0x43, count: 40_000),
            Data("tail".utf8)
        ]
        let session = attachmentChunkedSession(chunks: chunks)

        let fileURL = try await AttachmentService.download(
            attachment: makeAttachment(name: "big.bin", url: "https://ntfy.example/big.bin"),
            serverURL: "https://ntfy.example",
            authToken: nil,
            to: cacheDir,
            session: session
        )

        let expected = chunks.reduce(into: Data()) { $0.append($1) }
        XCTAssertEqual(try Data(contentsOf: fileURL), expected)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        XCTAssertEqual(leftovers.count, 1)
        XCTAssertFalse(leftovers[0].hasPrefix("."))
    }

    func testCancellationMidStreamRemovesTheTempFile() async throws {
        // Deliver one chunk, then hang without finishing: the temp file must exist
        // while the task is alive and disappear after cancellation.
        let session = attachmentChunkedSession(
            chunks: [Data(repeating: 0x01, count: 8_000), Data(repeating: 0x02, count: 8_000)],
            hangAfterChunks: 1
        )

        let attachment = makeAttachment(name: "hang.bin", url: "https://ntfy.example/hang.bin")
        let directory = cacheDir
        let task = Task {
            try await AttachmentService.download(
                attachment: attachment,
                serverURL: "https://ntfy.example",
                authToken: nil,
                to: directory,
                session: session
            )
        }

        var tempURL: URL?
        for _ in 0..<100 where tempURL == nil {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: cacheDir, includingPropertiesForKeys: nil
            )) ?? []
            tempURL = items.first { $0.lastPathComponent.hasPrefix(".") }
            if tempURL == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertNotNil(tempURL, "streaming download must create a .tmp file before completing")

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled download must throw")
        } catch {
            // Any error (CancellationError / URLError) is acceptable — cleanup is the point.
        }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        XCTAssertTrue(leftovers.isEmpty, "cancelled download left files: \(leftovers)")
    }

    // MARK: - PR8: LRU trimming

    func testTrimCacheRemovesOldestUntilHysteresisTarget() throws {
        let fm = FileManager.default
        for (name, ageSeconds) in [("a", 400), ("b", 300), ("c", 200), ("d", 100)] {
            let url = cacheDir.appendingPathComponent(name)
            try Data(repeating: 0, count: 10).write(to: url)
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -TimeInterval(ageSeconds))],
                ofItemAtPath: url.path
            )
        }

        // maxFiles 3 → 80% target is 2 files.
        try AttachmentService.trimCache(
            directory: cacheDir,
            policy: .init(maxBytes: 0, maxFiles: 3)
        )
        XCTAssertEqual(
            Set(try fm.contentsOfDirectory(atPath: cacheDir.path)),
            ["c", "d"]
        )
    }

    func testTrimCacheRespectsByteLimit() throws {
        let fm = FileManager.default
        // 4 × 10 bytes = 40; maxBytes 25 → target 20 bytes (2 files).
        for (name, ageSeconds) in [("a", 400), ("b", 300), ("c", 200), ("d", 100)] {
            let url = cacheDir.appendingPathComponent(name)
            try Data(repeating: 0, count: 10).write(to: url)
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -TimeInterval(ageSeconds))],
                ofItemAtPath: url.path
            )
        }

        try AttachmentService.trimCache(
            directory: cacheDir,
            policy: .init(maxBytes: 25, maxFiles: 0)
        )
        XCTAssertEqual(
            Set(try fm.contentsOfDirectory(atPath: cacheDir.path)),
            ["c", "d"]
        )
    }

    func testTrimCacheIsNoopUnderLimits() throws {
        let fm = FileManager.default
        let url = cacheDir.appendingPathComponent("only")
        try Data([1, 2, 3]).write(to: url)

        try AttachmentService.trimCache(
            directory: cacheDir,
            policy: .standard
        )
        XCTAssertTrue(fm.fileExists(atPath: url.path))
    }

    func testSmallPolicyTrimsAcrossFiveDownloadsKeepingNewest() async throws {
        let policy = AttachmentService.AttachmentCachePolicy(maxBytes: 0, maxFiles: 3) // target 2
        for i in 0..<5 {
            let session = attachmentMockSession(
                status: 200, body: Data("body-\(i)".utf8)
            )
            _ = try await AttachmentService.download(
                attachment: makeAttachment(name: "f\(i).bin", url: "https://ntfy.example/f\(i)"),
                serverURL: "https://ntfy.example",
                authToken: nil,
                to: cacheDir,
                policy: policy,
                session: session
            )
        }

        let remaining = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertFalse(remaining.contains { $0.hasPrefix(".") })
        // The two newest content-addressed files survive; their bodies prove which.
        let bodies = Set(
            try remaining.map {
                String(data: try Data(contentsOf: cacheDir.appendingPathComponent($0)), encoding: .utf8)!
            }
        )
        XCTAssertEqual(bodies, ["body-3", "body-4"])
    }

    func testCacheHitRefreshesModificationDateAndSkipsRequest() async throws {
        let url = "https://ntfy.example/cached.bin"
        _ = try await AttachmentService.download(
            attachment: makeAttachment(name: "cached.bin", url: url),
            serverURL: "https://ntfy.example",
            authToken: nil,
            to: cacheDir,
            session: attachmentMockSession(status: 200, body: Data("first".utf8))
        )

        let oldDate = Date(timeIntervalSinceNow: -3_600)
        let fileURL = cacheDir.appendingPathComponent(
            try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)[0]
        )
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: fileURL.path
        )

        let hit = try await AttachmentService.download(
            attachment: makeAttachment(name: "cached.bin", url: url),
            serverURL: "https://ntfy.example",
            authToken: nil,
            to: cacheDir,
            session: attachmentMockSession(status: 200, body: Data("second".utf8))
        )

        XCTAssertEqual(hit, fileURL)
        XCTAssertTrue(AttachmentMockProtocol.requests.isEmpty)
        let mtime = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        XCTAssertGreaterThan(mtime?.timeIntervalSince(oldDate) ?? 0, 3_000)
    }
}

/// URLProtocol that delivers the body in separate chunks, optionally hanging
/// (never finishing) after N chunks so a cancelled streaming download can be tested.
final class AttachmentChunkedMockProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _chunks: [Data] = []
    nonisolated(unsafe) private static var _status = 200
    nonisolated(unsafe) private static var _hangAfter: Int?

    static func reset(status: Int = 200, chunks: [Data], hangAfterChunks: Int?) {
        lock.lock()
        _chunks = chunks
        _status = status
        _hangAfter = hangAfterChunks
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let chunks = Self._chunks
        let status = Self._status
        let hangAfter = Self._hangAfter
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for (index, chunk) in chunks.enumerated() {
            client?.urlProtocol(self, didLoad: chunk)
            if let hangAfter, index + 1 == hangAfter { return } // hang until cancel
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // URLSession cancels the hung load: surface it so bytes(for:) throws.
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
}

func attachmentChunkedSession(
    status: Int = 200,
    chunks: [Data],
    hangAfterChunks hang: Int? = nil
) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AttachmentChunkedMockProtocol.self]
    AttachmentChunkedMockProtocol.reset(
        status: status, chunks: chunks, hangAfterChunks: hang
    )
    return URLSession(configuration: config)
}

// MARK: - Real TCP loopback server (exercises the actual URLSession bytes path)

/// Minimal HTTP/1.1 server over `NWListener` on 127.0.0.1, so the streaming
/// download runs through the real TCP stack rather than an NSURLProtocol mock.
/// `.dropConnectionAfter` sends part of the declared body then hard-closes,
/// emulating a mid-transfer network failure.
/// All mutable state lives on one serial queue; Sendable safety is manual by construction.
final class LoopbackHTTPServer: @unchecked Sendable {
    enum Mode {
        case full(Data)
        case dropConnectionAfter(Int)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ntfyx.tests.loopback-http")
    private let body: Data
    private let deliver: Int?
    private var _requestLines: [String] = []
    private var servedFirstConnection = false
    /// Held for the server's lifetime: the connection's FIN half-close stays
    /// valid after start() returns, and teardown happens with the listener.
    private var activeConnection: LoopbackConnection?

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var url: String { "http://127.0.0.1:\(port)/pr8-smoke.txt" }
    var requestLines: [String] { queue.sync { _requestLines } }

    init(mode: Mode) throws {
        switch mode {
        case .full(let data):
            body = data; deliver = nil
        case .dropConnectionAfter(let count):
            var data = Data()
            data.append(contentsOf: 0..<UInt8.max) // 255-byte ramp
            data.append(Data(repeating: 0x5a, count: 200_000))
            body = data; deliver = min(count, data.count)
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"), port: .any
        )
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        // Strong self is deliberate: listener lives until stop(); the test's
        // defer { stop() } cancels the listener and breaks the retain cycle.
        listener.newConnectionHandler = { conn in
            if self.servedFirstConnection {
                // A mid-response retry must fail fast instead of looping to timeout.
                conn.cancel()
                return
            }
            self.servedFirstConnection = true
            self.activeConnection = LoopbackConnection(
                conn: conn, queue: self.queue, body: self.body, deliver: self.deliver
            ) { line in
                self._requestLines.append(line)
            }
            self.activeConnection?.start()
        }
        listener.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
    }

    func stop() { listener.cancel() }
}

/// Reads one request on its server's serial queue, then replies once.
private final class LoopbackConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let body: Data
    private let deliver: Int?
    private let onRequestLine: (String) -> Void
    private var request = Data()

    init(
        conn: NWConnection,
        queue: DispatchQueue,
        body: Data,
        deliver: Int?,
        onRequestLine: @escaping (String) -> Void
    ) {
        self.conn = conn
        self.queue = queue
        self.body = body
        self.deliver = deliver
        self.onRequestLine = onRequestLine
    }

    func start() {
        conn.start(queue: queue)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else {
                self?.conn.cancel()
                return
            }
            self.request.append(data)
            if self.request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond()
            } else {
                self.receive()
            }
        }
    }

    private func respond() {
        if let line = String(data: request.prefix(while: { $0 != 0x0d }), encoding: .ascii) {
            onRequestLine(line)
        }
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "Content-Type: text/plain\r\n\r\n"
        let payload = Data(head.utf8) + (deliver.map { body.prefix($0) } ?? body[...])
        // finalMessage + isComplete emits a graceful FIN right after the
        // (possibly truncated) body, so the client drains what arrived and
        // immediately sees an early end-of-stream (partial-file error).
        conn.send(
            content: payload, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    deinit { conn.cancel() }
}

extension AttachmentServiceTests {
    func testRealTCPServerStreamsFileIntact() async throws {
        let pattern = Data("PR8-REAL-TCP-STREAMING-".utf8)
        var body = Data()
        while body.count < 150_019 { body.append(pattern) }
        body = body.prefix(150_019) + Data("<<<END>>>".utf8)
        let server = try LoopbackHTTPServer(mode: .full(body))
        defer { server.stop() }

        let fileURL = try await AttachmentService.download(
            attachment: .init(
                name: "pr8-smoke.txt", url: server.url, type: "text/plain", size: body.count, expires: nil
            ),
            serverURL: server.url,
            authToken: nil,
            to: cacheDir,
            session: .ephemeral
        )

        XCTAssertEqual(try Data(contentsOf: fileURL), body)
        XCTAssertTrue(server.requestLines.first?.hasPrefix("GET ") == true)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        XCTAssertEqual(leftovers.count, 1)
        XCTAssertFalse(leftovers[0].hasPrefix("."))
    }

    func testRealTCPServerMidStreamDropRemovesTempFile() async throws {
        let server = try LoopbackHTTPServer(mode: .dropConnectionAfter(70_000))
        defer { server.stop() }

        do {
            _ = try await AttachmentService.download(
                attachment: .init(
                    name: "drop.bin", url: server.url, type: "application/octet-stream",
                    size: nil, expires: nil
                ),
                serverURL: server.url,
                authToken: nil,
                to: cacheDir,
                session: .ephemeral
            )
            XCTFail("truncated response must throw")
        } catch {
            // URLSession reports the short Content-Length body as a transport error.
        }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        XCTAssertTrue(leftovers.isEmpty, "dropped download left files: \(leftovers)")
    }
}

private extension URLSession {
    static var ephemeral: URLSession { URLSession(configuration: .ephemeral) }
}
