import XCTest
import Network
import os
@testable import NtfyxCore

@MainActor
final class LocalNotificationServerTests: XCTestCase {
    var server: LocalNotificationServer!
    let testPort: UInt16 = 19292  // Use a non-standard port for tests
    let testToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    override func setUp() async throws {
        try await super.setUp()
        server = LocalNotificationServer(port: testPort, token: testToken)
        await server.setOnNotification(nil)  // Disable actual notifications in tests
        try await server.start()
        // Give the server time to start
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    override func tearDown() async throws {
        await server.stop()
        server = nil
        // Give the server time to release the port
        try await Task.sleep(nanoseconds: 300_000_000)
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// The listener only serves 127.0.0.1; a request to any non-loopback address cannot
    /// reach it. (A listener pinned to `::1` was tried first but it does not accept IPv4
    /// callers on macOS, so the explicit IPv4 loopback bind is the one we use.)
    private func sendRequest(
        method: String = "POST", path: String = "/notify",
        body: String? = nil, authorize: Bool = true,
        authorizationHeader: String? = nil
    ) async -> (statusCode: Int, body: String)? {
        guard let url = URL(string: "http://127.0.0.1:\(testPort)\(path)") else {
            XCTFail("Invalid URL")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        } else if authorize {
            request.setValue("Bearer \(testToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body.data(using: .utf8)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            return (statusCode, body)
        } catch {
            // URLSession maps non-2xx returned by our server into normal responses, so a
            // transport error is a genuine failure worth surfacing.
            XCTFail("Request failed: \(error)")
            return nil
        }
    }

    /// Sends raw bytes and returns the raw response, used for requests URLSession refuses
    /// to build (malformed request lines). Fails fast (empty result) instead of hanging the
    /// suite if the connection never establishes.
    private func sendRaw(_ raw: String) async -> String {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "local-server-raw-test")
            let connection = NWConnection(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: testPort)!, using: .tcp
            )
            let didFinish = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ result: String) {
                let alreadyDone = didFinish.withLock { state -> Bool in
                    guard !state else { return true }
                    state = true
                    return false
                }
                guard !alreadyDone else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: raw.data(using: .utf8),
                        completion: .contentProcessed { _ in
                            connection.receive(
                                minimumIncompleteLength: 1, maximumLength: 4096
                            ) { data, _, _, _ in
                                finish(data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
                            }
                        }
                    )
                case .failed, .cancelled:
                    finish("")
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + 3) { finish("") }
            connection.start(queue: queue)
        }
    }

    // MARK: - Authentication

    func testPostWithoutTokenIsRejected() async throws {
        let result = await sendRequest(
            body: "{\"title\": \"T\", \"message\": \"M\"}", authorize: false
        )
        XCTAssertEqual(result?.statusCode, 401)
        XCTAssertTrue(result?.body.contains("Unauthorized") ?? false)
    }

    func testPostWithWrongTokenIsRejected() async throws {
        let result = await sendRequest(
            body: "{\"title\": \"T\", \"message\": \"M\"}",
            authorizationHeader: "Bearer deadbeef"
        )
        XCTAssertEqual(result?.statusCode, 401)
    }

    func testPostWithMalformedAuthorizationHeaderIsRejected() async throws {
        let result = await sendRequest(
            body: "{\"title\": \"T\", \"message\": \"M\"}",
            authorizationHeader: "Token \(testToken)"
        )
        XCTAssertEqual(result?.statusCode, 401)
    }

    // MARK: - Health Check

    func testHealthCheckNeedsNoToken() async throws {
        let result = await sendRequest(method: "GET", path: "/health", authorize: false)
        XCTAssertEqual(result?.statusCode, 200)
        XCTAssertTrue(result?.body.contains("\"status\":\"ok\"") ?? false)
    }

    // MARK: - POST /notify

    func testValidNotification() async throws {
        let body = """
        {"title": "Test", "message": "Hello World"}
        """
        let result = await sendRequest(body: body)
        XCTAssertEqual(result?.statusCode, 200)
        XCTAssertTrue(result?.body.contains("\"success\":true") ?? false)
    }

    func testNotificationWithAllFields() async throws {
        let body = """
        {"title": "Alert", "message": "Server down", "priority": 5, "tags": ["warning", "fire"]}
        """
        let result = await sendRequest(body: body)
        XCTAssertEqual(result?.statusCode, 200)
        XCTAssertTrue(result?.body.contains("\"success\":true") ?? false)
    }

    func testMissingTitle() async throws {
        let body = """
        {"message": "No title here"}
        """
        let result = await sendRequest(body: body)
        XCTAssertEqual(result?.statusCode, 400)
        XCTAssertTrue(result?.body.contains("title") ?? false)
    }

    func testMissingMessage() async throws {
        let body = """
        {"title": "No message"}
        """
        let result = await sendRequest(body: body)
        XCTAssertEqual(result?.statusCode, 400)
        XCTAssertTrue(result?.body.contains("message") ?? false)
    }

    func testEmptyTitle() async throws {
        let body = """
        {"title": "", "message": "Hello"}
        """
        let result = await sendRequest(body: body)
        XCTAssertEqual(result?.statusCode, 400)
        XCTAssertTrue(result?.body.contains("title") ?? false)
    }

    func testEmptyMessage() async throws {
        let body = """
        {"title": "Test", "message": ""}
        """
        let result = await sendRequest(body: body)
        XCTAssertEqual(result?.statusCode, 400)
        XCTAssertTrue(result?.body.contains("message") ?? false)
    }

    func testInvalidJSON() async throws {
        let result = await sendRequest(body: "not json at all")
        XCTAssertEqual(result?.statusCode, 400)
        XCTAssertTrue(result?.body.contains("Invalid JSON") ?? false)
    }

    // MARK: - Wrong Path / Method

    func testWrongPath() async throws {
        let result = await sendRequest(method: "GET", path: "/wrong", authorize: false)
        XCTAssertEqual(result?.statusCode, 404)
    }

    func testGetOnNotify() async throws {
        let result = await sendRequest(method: "GET", path: "/notify", authorize: false)
        XCTAssertEqual(result?.statusCode, 404)
    }

    // MARK: - Hardening

    func testMalformedRequestLineIsRejected() async {
        let response = await sendRaw("GARBAGE\r\n\r\n")
        XCTAssertTrue(response.contains("400"), "expected 400, got: \(response)")
    }

    func testUnauthenticatedRawPostIsRejected() async {
        let body = "{\"title\":\"T\",\"message\":\"M\"}"
        let raw = """
        POST /notify HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)
        """
        let response = await sendRaw(raw)
        XCTAssertTrue(response.contains("401"), "expected 401, got: \(response)")
        XCTAssertTrue(response.contains("WWW-Authenticate: Bearer"), "missing challenge: \(response)")
    }
}
