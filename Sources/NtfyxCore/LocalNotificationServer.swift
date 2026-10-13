import Foundation
import Network

/// A minimal HTTP server bound to the loopback interface that accepts authenticated POST
/// requests to trigger local macOS notifications. This allows scripts (e.g. auto_run_script)
/// to generate notifications without going through an external ntfy server.
///
/// Usage: POST http://127.0.0.1:<port>/notify
///   Headers: Authorization: Bearer <token from ~/Library/Application Support/ntfyx/local-token>
///   Body: {"title": "...", "message": "...", "priority": 3, "tags": ["warning"]}
///
/// The server is an actor: all mutable listener state is isolated, and the Network.framework
/// callbacks hop back in here over `Task`s. Per-connection buffering travels as method
/// parameters, so no connection state is shared between callbacks.
actor LocalNotificationServer {
    private var listener: NWListener?
    nonisolated let port: UInt16
    nonisolated let token: String
    nonisolated private let maxBodySize = 4096
    nonisolated private let queue = DispatchQueue(label: "com.ntfyx.local-server")

    /// Accepted connections and the Swift tasks driving their request state machines.
    /// `stop()` cancels and awaits every one of them: when the test suite (or a config
    /// reload) lets the server go, no callback task may outlive it — such orphan tasks
    /// hopping back onto a dead actor crash the process with
    /// "freed pointer was not the last allocation".
    private var activeConnections: [NWConnection] = []
    /// Worker tasks driving the per-connection state machines, kept so `stop()` can
    /// cancel them. Removal is driven through `activeCount`, never by awaiting the
    /// tasks from inside the actor: a `.value` that resolves immediately does not
    /// suspend the caller and would spin on the main executor, starving the very
    /// removal hops that shrink the set.
    private var connectionTasks: [Task<Void, Never>] = []
    private var activeCount = 0
    /// Resumed (once) when a draining `stop()` observes `activeCount == 0`.
    private var drainContinuation: CheckedContinuation<Void, Never>?
    /// Once `stop()` begins, tasks arriving late (cancel callbacks that were already in
    /// flight) are cancelled the moment they register.
    private var isStopping = false

    /// Callback for handling notifications. Set to nil to disable notification display
    /// (used by tests).
    private var onNotification: (@Sendable (NtfyMessage) -> Void)?

    /// Production initializer: loads the per-machine bearer token from disk, creating it
    /// (with `0600` permissions) on first launch.
    init(port: UInt16) throws {
        try self.init(port: port, token: LocalAPIToken.load())
    }

    /// Designated initializer with an injected token (tests use a known value).
    init(port: UInt16, token: String) {
        self.port = port
        self.token = token
        // Default delivery goes through the app's notification manager on the main actor;
        // tests replace this with nil before starting the listener.
        self.onNotification = { message in
            Task { @MainActor in
                NotificationManager.shared.showNotification(for: message, topicConfig: nil)
            }
        }
    }

    func setOnNotification(_ handler: (@Sendable (NtfyMessage) -> Void)?) {
        onNotification = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        // Loopback only: bind the IPv4 loopback explicitly (a listener pinned to ::1 does
        // NOT accept 127.0.0.1 callers — verified on macOS, there is no implicit dual
        // stack here). Off-machine callers cannot route to 127.0.0.1.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!
        )

        let listener = try NWListener(using: params)

        listener.newConnectionHandler = { [weak self] connection in
            self?.track(Task { [weak self] in
                await self?.handleConnection(connection)
            })
        }

        listener.stateUpdateHandler = { [port] state in
            switch state {
            case .ready:
                Log.info("Local notification server listening on 127.0.0.1:\(port)")
            case .failed(let error):
                Log.error("Local notification server failed: \(error)")
            case .cancelled:
                Log.info("Local notification server stopped")
            default:
                break
            }
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    /// Cancel the listener and every in-flight connection, then wait for all their
    /// callback tasks to have finished. The caller can tear the actor down afterwards
    /// without risking an orphan task.
    func stop() async {
        isStopping = true
        listener?.cancel()
        listener = nil
        for connection in activeConnections { connection.cancel() }
        for task in connectionTasks { task.cancel() }
        connectionTasks.removeAll()

        // Suspend for real until every worker's removal hop reports the count at zero.
        // Late callback workers (their receive was already cancelled) still register,
        // run to completion against the cancelled connection, and decrement the count;
        // the continuation resumes only after the last one.
        if activeCount > 0 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                drainContinuation = continuation
            }
        }
        activeConnections.removeAll()
    }

    /// Register an already-created worker task and attach a separate reaper that removes
    /// it from the live set once it finishes. Both tasks capture only `let`s (Sendable),
    /// unlike a worker that would capture its own mutable task handle — that capture made
    /// the closure non-Sendable under Swift 6.
    nonisolated private func track(_ worker: Task<Void, Never>) {
        Task { [weak self] in
            await self?.registerConnectionTask(worker)
        }
        Task { [weak self] in
            await worker.value
            await self?.finishConnectionWork(worker)
        }
    }

    private func registerConnectionTask(_ task: Task<Void, Never>) {
        activeCount += 1
        if isStopping {
            task.cancel()
        } else {
            connectionTasks.append(task)
        }
    }

    private func finishConnectionWork(_ task: Task<Void, Never>) {
        activeCount -= 1
        if isStopping, activeCount == 0 {
            drainContinuation?.resume()
            drainContinuation = nil
        }
    }

    /// Connections that completed their request are dropped from the live set; only
    /// connections still mid-request need to be cancelled by `stop()`.
    private func retire(_ connection: NWConnection) {
        if let index = activeConnections.firstIndex(where: { $0 === connection }) {
            activeConnections.remove(at: index)
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        activeConnections.append(connection)
        connection.start(queue: queue)
        readData(connection: connection, buffer: Data())
    }

    /// Accumulates data from the connection until the full HTTP request is received.
    private func readData(connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: maxBodySize + 2048
        ) { [weak self] data, _, isComplete, error in
            self?.track(Task { [weak self] in
                await self?.consume(
                    connection: connection, buffer: buffer, data: data,
                    isComplete: isComplete, error: error
                )
            })
        }
    }

    private func consume(
        connection: NWConnection, buffer: Data, data: Data?,
        isComplete: Bool, error: NWError?
    ) {
        if let error {
            Log.error("Local server connection error: \(error)")
            retire(connection)
            connection.cancel()
            return
        }

        var accumulated = buffer
        if let data { accumulated.append(data) }

        // Check if we have the complete HTTP request.
        if let raw = String(data: accumulated, encoding: .utf8),
           let headerEnd = raw.range(of: "\r\n\r\n") {
            let headers = String(raw[..<headerEnd.lowerBound])
            let bodyStart = raw[headerEnd.upperBound...]
            let contentLength = parseContentLength(from: headers)

            if bodyStart.utf8.count >= contentLength || isComplete {
                processRequest(data: accumulated, connection: connection)
                return
            }
        }

        if isComplete {
            // Connection closed: process what we have, or reject an empty read.
            if accumulated.isEmpty {
                retire(connection)
                Self.sendResponse(connection: connection, status: 400, body: "{\"error\":\"No data received\"}")
            } else {
                processRequest(data: accumulated, connection: connection)
            }
            return
        }

        // Need more data, keep reading until the hard ceiling.
        if accumulated.count > maxBodySize + 4096 {
            retire(connection)
            Self.sendResponse(connection: connection, status: 413, body: "{\"error\":\"Request too large\"}")
            return
        }

        readData(connection: connection, buffer: accumulated)
    }

    /// Parse Content-Length header value from raw headers string.
    private nonisolated func parseContentLength(from headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    /// MARK: - Bearer authentication

    /// Verifies the `Authorization: Bearer <token>` header against this machine's token.
    private nonisolated func isAuthorized(_ headers: String) -> Bool {
        for line in headers.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            guard parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "authorization" else {
                continue
            }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value.lowercased().hasPrefix("bearer ") else { return false }
            let presented = String(value.dropFirst("bearer ".count))
                .trimmingCharacters(in: .whitespaces)
            // Constant-time compare: token equality must not be timing-observable.
            return presented.utf8.withContiguousStorageIfAvailable { presentedBytes in
                token.utf8.withContiguousStorageIfAvailable { tokenBytes in
                    constantTimeEquals(presentedBytes, tokenBytes)
                } ?? false
            } ?? false
        }
        return false
    }

    private nonisolated func constantTimeEquals(
        _ lhs: UnsafeBufferPointer<UTF8.CodeUnit>,
        _ rhs: UnsafeBufferPointer<UTF8.CodeUnit>
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }

    private func processRequest(data: Data, connection: NWConnection) {
        // Every path through this method writes a terminal response and closes the
        // connection, so it leaves the live set immediately.
        retire(connection)
        guard let raw = String(data: data, encoding: .utf8) else {
            Self.sendResponse(connection: connection, status: 400, body: "{\"error\":\"Invalid encoding\"}")
            return
        }

        // Parse HTTP request line.
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first,
              let headerEndRange = raw.range(of: "\r\n\r\n") else {
            Self.sendResponse(connection: connection, status: 400, body: "{\"error\":\"Malformed request\"}")
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count == 3, String(parts[2]) == "HTTP/1.1" else {
            Self.sendResponse(connection: connection, status: 400, body: "{\"error\":\"Malformed request line\"}")
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])
        let headers = String(raw[..<headerEndRange.lowerBound])

        // Only accept POST /notify; the liveness probe stays unauthenticated.
        guard method == "POST" && path == "/notify" else {
            if method == "GET" && path == "/health" {
                Self.sendResponse(connection: connection, status: 200, body: "{\"status\":\"ok\"}")
                return
            }
            Self.sendResponse(
                connection: connection, status: 404,
                body: "{\"error\":\"Not found. Use POST /notify or GET /health\"}"
            )
            return
        }

        // Authenticate before touching the body: an unauthenticated caller gets no parsing
        // behaviour and no indication beyond the generic 401.
        guard isAuthorized(headers) else {
            Self.sendResponse(
                connection: connection, status: 401,
                body: "{\"error\":\"Unauthorized. Provide Authorization: Bearer <local-token>\"}",
                extraHeaders: "WWW-Authenticate: Bearer realm=\"ntfyx-local\", charset=\"UTF-8\"\r\n"
            )
            return
        }

        let bodyString = String(raw[headerEndRange.upperBound...])
        guard bodyString.utf8.count <= maxBodySize else {
            Self.sendResponse(
                connection: connection, status: 413,
                body: "{\"error\":\"Body too large (max \(maxBodySize) bytes)\"}"
            )
            return
        }

        guard let bodyData = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            Self.sendResponse(connection: connection, status: 400, body: "{\"error\":\"Invalid JSON\"}")
            return
        }

        // Parse notification fields.
        guard let title = json["title"] as? String, !title.isEmpty else {
            Self.sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing required field: title\"}")
            return
        }
        guard let message = json["message"] as? String, !message.isEmpty else {
            Self.sendResponse(connection: connection, status: 400, body: "{\"error\":\"Missing required field: message\"}")
            return
        }

        let priority = json["priority"] as? Int
        let tags = json["tags"] as? [String]

        Log.info("Local notification: \(title) - \(message)")

        let localMessage = NtfyMessage(
            id: UUID().uuidString,
            time: Int(Date().timeIntervalSince1970),
            event: "message",
            topic: "local",
            message: message,
            title: title,
            priority: priority,
            tags: tags,
            click: nil,
            actions: nil,
            attachment: nil,
            contentType: nil,
            sequenceId: nil
        )

        onNotification?(localMessage)

        Self.sendResponse(connection: connection, status: 200, body: "{\"success\":true}")
    }

    private nonisolated static func sendResponse(
        connection: NWConnection, status: Int, body: String, extraHeaders: String = ""
    ) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 413: statusText = "Payload Too Large"
        default: statusText = "Error"
        }

        let response = """
        HTTP/1.1 \(status) \(statusText)\r\n\
        Content-Type: application/json\r\n\
        Content-Length: \(body.utf8.count)\r\n\
        \(extraHeaders)\
        Connection: close\r\n\r\n\
        \(body)
        """

        connection.send(
            content: response.data(using: .utf8),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }
}
