import XCTest
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
}
