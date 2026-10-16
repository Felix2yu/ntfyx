import Foundation
import Network

struct NtfyMessage: Codable {
    let id: String
    let time: Int
    let event: String
    let topic: String
    let message: String?
    let title: String?
    let priority: Int?
    let tags: [String]?
    let click: String?
    let actions: [NtfyAction]?
    let attachment: NtfyAttachment?
    let contentType: String?  // "text/markdown" when markdown is enabled
    let sequenceId: String?   // fork extension: stable id for update/delete/clear operations

    enum CodingKeys: String, CodingKey {
        case id, time, event, topic, message, title, priority, tags, click, actions, attachment
        case contentType = "content_type"
        case sequenceId = "sequence_id"
    }

    /// Server events that act on an already-published message. `clearEvent` is what the
    /// server broadcasts for `/<topic>/<seq>/read|clear`, i.e. "mark as read".
    static let deleteEvent = "message_delete"
    static let clearEvent = "message_clear"

    /// True for events that change an existing message instead of delivering a new one.
    var isActionEvent: Bool {
        event == Self.deleteEvent || event == Self.clearEvent
    }

    /// Returns true if this message contains markdown content
    var isMarkdown: Bool {
        contentType?.lowercased() == "text/markdown"
    }

    /// Returns the message with markdown syntax stripped for plain text display
    var plainTextMessage: String? {
        guard let message = message else { return nil }
        guard isMarkdown else { return message }
        return MarkdownStripper.strip(message)
    }

    /// Returns the title with markdown syntax stripped for plain text display
    var plainTextTitle: String? {
        guard let title = title else { return nil }
        guard isMarkdown else { return title }
        return MarkdownStripper.strip(title)
    }

    struct NtfyAction: Codable {
        let action: String
        let label: String
        let url: String?
        let method: String?
        let headers: [String: String]?
        let body: String?
        let clear: Bool?
    }

    struct NtfyAttachment: Codable {
        let name: String
        let url: String
        let type: String?
        let size: Int?
        let expires: Int?
    }
}

/// Errors the SSE client can itself produce. Transport errors reported by the server stack
/// arrive as URLSession errors through the event stream.
enum NtfyClientError: Error, LocalizedError, Sendable {
    /// The configured server URL can never build a valid request URL (e.g. illegal characters).
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return L10n.format("服务器地址无效：%@", url)
        }
    }
}

/// Everything the connection actor reports to the main-actor coordinator. Transport errors
/// are bridged to `NSError` (which is Sendable) at the URLSession boundary.
enum NtfyClientEvent: Sendable {
    case connected
    case disconnected
    case message(NtfyMessage)
    case actionEvent(NtfyMessage)
    /// Replayed history (`since=all` / `since=<watermark>`), one event per network chunk,
    /// capped at `NtfyClient.maxCatchUpBatchSize`.
    case catchUpBatch([NtfyMessage])
    case failure(NSError)
}

/// One transport-level fact reported by the URLSession delegate into the actor. A single
/// `AsyncStream` consumer is what keeps NDJSON line ordering intact without locks.
private enum TransportInput: Sendable {
    case data(Data)
    case opened
    case rejected(status: Int, retryAfterHeader: String?)
    case completed(error: NSError?)
    /// URLSession finished tearing down after `invalidateAndCancel()`: the delegate is
    /// released past this point.
    case invalidated
}

/// Stateless URLSession delegate: it holds only `let` Sendable sinks, so the checked
/// `Sendable` conformance needs no `@unchecked` escape hatch. All state lives in the actor.
private final class SessionTransport: NSObject, URLSessionDataDelegate, Sendable {
    private let enqueue: @Sendable (TransportInput) -> Void

    init(enqueue: @escaping @Sendable (TransportInput) -> Void) {
        self.enqueue = enqueue
    }

    func urlSession(
        _ session: URLSession, didBecomeInvalidWithError error: Error?
    ) {
        enqueue(.invalidated)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
    ) {
        enqueue(.data(data))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        enqueue(.completed(error: error.map { $0 as NSError }))
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }

        if httpResponse.statusCode == 200 {
            completionHandler(.allow)
            enqueue(.opened)
        } else {
            // A refused subscription only recovers by reconnecting. The .cancel below makes
            // URLSession report a cancelled error, which the actor swallows as an already
            // handled response.
            completionHandler(.cancel)
            enqueue(.rejected(
                status: httpResponse.statusCode,
                retryAfterHeader: httpResponse.value(forHTTPHeaderField: "Retry-After")
            ))
        }
    }
}

/// Owns one SSE subscription: the URLSession task, NDJSON framing, the fetch-missed
/// watermark, reconnection backoff, the staleness watchdog and the network-path monitor.
/// All of that state is actor-isolated (audit B1); the outside world only sees the
/// `events` stream and the connect/disconnect/updateAuthToken commands.
actor NtfyClient {
    nonisolated let serverURL: String
    nonisolated let topics: [String]
    nonisolated private let fetchMissed: Bool
    nonisolated private let watchdogInterval: TimeInterval
    nonisolated private let baseReconnectDelay: TimeInterval
    nonisolated private let maxReconnectDelay: TimeInterval = 300.0
    nonisolated private let maxReconnectAttempts = 10

    /// Outbound lifecycle and message events for the owner.
    nonisolated let events: AsyncStream<NtfyClientEvent>
    private nonisolated let eventContinuation: AsyncStream<NtfyClientEvent>.Continuation

    private let session: URLSession
    private var dataTask: URLSessionDataTask?
    private var buffer = Data()

    /// Continuation feeding the single transport consumer. It is created in `init` and
    /// finished when the URLSession has invalidated, so the consumer task never outlives
    /// the session's delegate.
    private var inboundContinuation: AsyncStream<TransportInput>.Continuation!
    /// `disconnect()` is terminal: after invalidation the session cannot be reused.
    private var didDisconnect = false
    private var isSessionInvalidated = false
    /// Resumed from the `.invalidated` transport input; lets `disconnect()` wait until
    /// URLSession has fully released its delegate and tasks.
    private var invalidationContinuation: CheckedContinuation<Void, Never>?

    private var authToken: String?

    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private var isConnecting = false
    private var shouldReconnect = true
    private var retryAfterDelay: TimeInterval?  // From Retry-After header
    /// Set when a non-200 response is rejected. The `.cancel` that follows makes URLSession
    /// report a cancelled error, which the completion reads as a deliberate disconnect;
    /// this flag lets the completion see it was already handled for this response.
    private var rejectedResponse = false
    private var lastMessageTime: Int  // Track last message timestamp for fetch_missed
    private nonisolated let lastMessageTimeKey: String  // UserDefaults key for persistence

    /// Wall-clock seconds at the last connect. Everything the server replays from its cache
    /// is older than this, so it is catch-up and goes through the batched path; a newer
    /// message is live traffic and keeps the immediate per-message path.
    private var catchUpCutoff = 0
    /// Catch-up messages waiting to be handed over, filled and drained on this actor.
    private var catchUpBatch: [NtfyMessage] = []

    // Watchdog: reconnect if no data received for this long (ntfy sends keepalives every ~55s)
    private var watchdogTask: Task<Void, Never>?
    private var lastDataReceived: Date = .distantPast

    // Network path monitor: reconnect immediately when network becomes available
    private var pathMonitor: NWPathMonitor?
    private var isPathSatisfied = true  // Assume connected initially

    init(
        serverURL: String, topics: [String], authToken: String? = nil,
        fetchMissed: Bool = false, watchdogInterval: TimeInterval = 120.0,
        baseReconnectDelay: TimeInterval = 2.0,
        urlSessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.serverURL = serverURL
        self.topics = topics
        self.authToken = authToken
        self.fetchMissed = fetchMissed
        self.watchdogInterval = watchdogInterval
        self.baseReconnectDelay = baseReconnectDelay

        // Restore last message time from UserDefaults for fetch_missed.
        // The key deliberately ignores the topic list: adding a subscription must not
        // discard the watermark of the topics that were already caught up, which used to
        // drop the connection back to `since=all` and replay every topic's whole cache.
        let key = Self.watermarkKey(serverURL: serverURL, fetchMissed: fetchMissed)
        self.lastMessageTimeKey = key
        self.lastMessageTime = UserDefaults.standard.integer(forKey: key)

        var eventContinuation: AsyncStream<NtfyClientEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { eventContinuation = $0 }
        self.eventContinuation = eventContinuation

        var inboundContinuation: AsyncStream<TransportInput>.Continuation!
        let inbound = AsyncStream<TransportInput>(bufferingPolicy: .unbounded) {
            inboundContinuation = $0
        }
        self.inboundContinuation = inboundContinuation

        let config = urlSessionConfiguration ?? URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        config.httpMaximumConnectionsPerHost = 1

        let transport = SessionTransport { [inboundContinuation] input in
            inboundContinuation.yield(input)
        }

        // A dedicated serial queue for URLSession callbacks, matching the single consumer
        // that drains `inbound`.
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "com.ntfyx.urlsession"
        session = URLSession(
            configuration: config, delegate: transport, delegateQueue: delegateQueue
        )

        // The consumer is not retained: it finishes on its own once the stream is
        // finished (disconnect) or the continuation is released with the session's
        // delegate (deinit fallback).
        Task { [weak self] in
            await self?.consumeTransportInputs(inbound)
        }
    }

    /// Upper bound of one catch-up handover, so a single huge network chunk cannot make
    /// the owner do thousands of inserts in one turn.
    static let maxCatchUpBatchSize = 500

    /// UserDefaults key of the fetch-missed watermark. Scoped to the server and the
    /// fetch-missed group, never to the topic list.
    static func watermarkKey(serverURL: String, fetchMissed: Bool) -> String {
        "lastMessageTime-\(serverURL)-\(fetchMissed ? 1 : 0)"
    }

    deinit {
        // A URLSession released while tasks still reference its delegate aborts with
        // "freed pointer was not the last allocation": invalidate first so the session
        // tears down (and releases) its tasks before the handle goes away.
        session.invalidateAndCancel()
        pathMonitor?.cancel()
    }

    // MARK: - Commands

    func connect() {
        // `disconnect()` is terminal. A zero-delay reconnect task that has already passed
        // its cancellation check must not create a fresh data task on the invalidating
        // URLSession (nor restart the path monitor): doing so races CFNetwork teardown.
        guard !didDisconnect else { return }
        guard !isConnecting else { return }
        isConnecting = true

        let topicsString = topics.joined(separator: ",")
        guard var components = URLComponents(string: serverURL) else {
            failInvalidURL()
            return
        }

        components.path = "/\(topicsString)/json"

        // Add since parameter to fetch missed messages when enabled
        if fetchMissed {
            if lastMessageTime > 0 {
                // Reconnect: only fetch messages since the last one we received
                components.queryItems = [URLQueryItem(name: "since", value: String(lastMessageTime))]
            } else {
                // First connect: fetch all cached messages
                components.queryItems = [URLQueryItem(name: "since", value: "all")]
            }
        }

        guard let url = components.url else {
            failInvalidURL()
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")

        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        startPathMonitor()

        buffer.removeAll()
        catchUpBatch.removeAll()
        catchUpCutoff = Int(Date().timeIntervalSince1970)
        rejectedResponse = false
        dataTask = session.dataTask(with: request)
        dataTask?.resume()

        Log.info("Connecting to ntfy: \(url.absoluteString)")
    }

    /// Terminal teardown. Invalidates the URLSession and waits for its asynchronous
    /// release of the delegate and internal tasks before returning, so the client can
    /// deallocate without a URLSession task outliving it (the
    /// "freed pointer was not the last allocation" abort). Repeated calls just wait for
    /// the first invalidation to finish.
    func disconnect() async {
        if !didDisconnect {
            didDisconnect = true
            shouldReconnect = false
            reconnectTask?.cancel()
            reconnectTask = nil
            stopWatchdog()
            stopPathMonitor()
            dataTask?.cancel()
            dataTask = nil
            isConnecting = false
            buffer.removeAll()
            session.invalidateAndCancel()
        }

        guard !isSessionInvalidated else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if isSessionInvalidated {
                continuation.resume()
            } else {
                invalidationContinuation = continuation
            }
        }
    }

    func updateAuthToken(_ token: String?) {
        authToken = token
        if dataTask != nil {
            scheduleReconnect()
        }
    }

    /// The server URL can never produce a valid request URL (e.g. an incomplete "https://").
    /// Reconnecting cannot fix that, so report the error and mark the server disconnected
    /// instead of hanging in "connecting" forever.
    private func failInvalidURL() {
        isConnecting = false
        let error = NtfyClientError.invalidURL(serverURL)
        Log.error("Invalid server URL: \(serverURL)")
        eventContinuation.yield(.failure(error as NSError))
        eventContinuation.yield(.disconnected)
    }

    // MARK: - Transport input

    private func consumeTransportInputs(_ inbound: AsyncStream<TransportInput>) async {
        for await input in inbound {
            switch input {
            case .data(let data):
                handleTransportData(data)
            case .opened:
                handleOpened()
            case .rejected(let status, let retryAfterHeader):
                handleRejected(status: status, retryAfterHeader: retryAfterHeader)
            case .completed(let error):
                handleCompleted(error: error)
            case .invalidated:
                sessionDidInvalidate()
            }
        }
    }

    /// Called on the consumer when URLSession reports the end of invalidation. The
    /// inbound stream is finished here (releasing the consumer task) and any awaiting
    /// `disconnect()` is allowed to return.
    private func sessionDidInvalidate() {
        guard !isSessionInvalidated else { return }
        isSessionInvalidated = true
        inboundContinuation.finish()
        invalidationContinuation?.resume()
        invalidationContinuation = nil
    }

    private func handleTransportData(_ data: Data) {
        lastDataReceived = Date()
        buffer.append(data)

        while let newlineRange = buffer.range(of: Data("\n".utf8)) {
            let lineData = buffer.subdata(in: 0..<newlineRange.lowerBound)
            buffer.removeSubrange(0..<newlineRange.upperBound)

            if let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) {
                processLine(line)
            }
        }

        // Each chunk is a handover point: the replay is delivered in chunk-sized batches,
        // which keeps the main thread free without holding messages back across chunks.
        flushCatchUpBatch()
    }

    private func handleOpened() {
        isConnecting = false
        reconnectAttempts = 0
        startWatchdog()
        eventContinuation.yield(.connected)
    }

    private func handleRejected(status: Int, retryAfterHeader: String?) {
        Log.error("Server returned status code: \(status)")

        // Handle rate limiting (429) - extract Retry-After header
        if status == 429 {
            if let retryAfterHeader {
                retryAfterDelay = HTTPRetryAfter.delay(forHeaderValue: retryAfterHeader)
            } else {
                // No Retry-After header, use a conservative default for 429
                retryAfterDelay = HTTPRetryAfter.fallbackDelay
            }
        }

        rejectedResponse = true
        eventContinuation.yield(.disconnected)
        scheduleReconnect()
    }

    private func handleCompleted(error: NSError?) {
        flushCatchUpBatch()
        isConnecting = false
        stopWatchdog()

        // A response the server refused (502/500/429/…) ends in our own .cancel, whose error
        // is indistinguishable from a deliberate disconnect. Swallow it here: the retry was
        // already scheduled when the response came in.
        if rejectedResponse {
            rejectedResponse = false
            return
        }

        if let error {
            // Cancelled errors are expected when we cancel the task ourselves (reconnect/disconnect) — ignore them
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                return
            }
            Log.error("Connection error: \(error.localizedDescription)")
            eventContinuation.yield(.failure(error))
            eventContinuation.yield(.disconnected)
            scheduleReconnect()
        } else {
            Log.info("Connection closed by server")
            eventContinuation.yield(.disconnected)
            if shouldReconnect {
                scheduleReconnect()
            }
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        stopWatchdog()
        lastDataReceived = Date()
        let interval = watchdogInterval
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.watchdogFired()
            }
        }
    }

    private func watchdogFired() {
        let elapsed = Date().timeIntervalSince(lastDataReceived)
        if elapsed >= watchdogInterval {
            Log.info("Watchdog: no data received for \(Int(elapsed))s, reconnecting...")
            scheduleReconnect()
        }
    }

    private func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    // MARK: - Network path

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { await self?.pathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: .global(qos: .background))
    }

    private func pathChanged(satisfied: Bool) {
        if satisfied && !isPathSatisfied {
            Log.info("Network became available, reconnecting...")
            scheduleReconnect()
        }
        isPathSatisfied = satisfied
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        isPathSatisfied = true
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        guard shouldReconnect else { return }

        dataTask?.cancel()
        dataTask = nil
        isConnecting = false

        // Calculate delay with exponential backoff
        var delay: TimeInterval

        if let retryAfter = retryAfterDelay {
            // Server told us exactly when to retry (Retry-After header)
            delay = retryAfter
            retryAfterDelay = nil  // Clear for next time
            Log.info("Server requested retry after \(Int(delay)) seconds")
        } else {
            // Exponential backoff: 2s, 4s, 8s, 16s, 32s, 64s, 128s, 256s, 300s (capped)
            delay = min(baseReconnectDelay * pow(2.0, Double(reconnectAttempts)), maxReconnectDelay)
        }

        // Add jitter (±10%) to prevent thundering herd
        delay += delay * Double.random(in: -0.1...0.1)

        reconnectAttempts += 1

        if reconnectAttempts > maxReconnectAttempts {
            // Max attempts reached — schedule a last-resort retry every 5 minutes indefinitely
            Log.error("Max reconnection attempts reached. Retrying every 5 minutes...")
            reconnectAttempts = 0
            delay = 300.0
        }

        Log.info("Reconnecting in \(String(format: "%.1f", delay)) seconds (attempt \(reconnectAttempts)/\(maxReconnectAttempts))...")

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }

    // MARK: - Stream decoding

    private func processLine(_ line: String) {
        guard !line.isEmpty else { return }

        do {
            let data = Data(line.utf8)
            let message = try JSONDecoder().decode(NtfyMessage.self, from: data)

            // Track latest message time for fetch_missed reconnects
            if message.time > lastMessageTime {
                lastMessageTime = message.time
            }

            let isCatchUp = fetchMissed && message.time <= catchUpCutoff
                && (message.event == "message" || message.isActionEvent)
            if isCatchUp {
                // A `since` replay is a burst, not a stream: hold it until the chunk ends
                // and hand it over in one go instead of queueing main-thread work per message.
                catchUpBatch.append(message)
                if catchUpBatch.count >= Self.maxCatchUpBatchSize { flushCatchUpBatch() }
                return
            }

            flushCatchUpBatch()  // keep the history in arrival order
            persistWatermark()

            if message.event == "message" {
                eventContinuation.yield(.message(message))
            } else if message.isActionEvent {
                eventContinuation.yield(.actionEvent(message))
            }
        } catch {
            Log.error("Failed to decode message: \(error)")
        }
    }

    /// Hands the buffered replay to the owner and stores the fetch-missed watermark.
    private func flushCatchUpBatch() {
        guard !catchUpBatch.isEmpty else { return }
        let batch = catchUpBatch
        catchUpBatch.removeAll(keepingCapacity: true)
        persistWatermark()
        eventContinuation.yield(.catchUpBatch(batch))
    }

    /// One UserDefaults write per batch rather than per message: the replay can carry tens
    /// of thousands of messages and every write round-trips to cfprefsd.
    private func persistWatermark() {
        guard fetchMissed, lastMessageTime > 0 else { return }
        UserDefaults.standard.set(lastMessageTime, forKey: lastMessageTimeKey)
    }
}
