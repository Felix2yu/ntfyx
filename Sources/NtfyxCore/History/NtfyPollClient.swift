import Foundation

/// Stateless poll client: fetches cached history from the server via
/// `GET {topic}/json?poll=1&since=...` (NDJSON stream), decoding line by line.
enum NtfyPollClient {

    /// Events handed to `onEvents` at once, matching `MessageStore.applyBatch`'s appetite:
    /// one transaction per chunk instead of one per row.
    static let eventBatchSize = 200

    /// Session configuration factory. Only here so the streaming decode path can be tested
    /// against a `URLProtocol`; the long resource timeout is real production behaviour — a
    /// full-history replay can run for minutes while time-to-first-byte stays bounded.
    static let defaultConfiguration: @Sendable () -> URLSessionConfiguration = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 3600
        return config
    }

    /// One session for every poll, held behind an actor so the lazily built session and the
    /// test-only configuration swap can never be touched concurrently.
    actor SessionPool {
        private var configuration: @Sendable () -> URLSessionConfiguration
        private var session: URLSession?

        init(configuration: @escaping @Sendable () -> URLSessionConfiguration = NtfyPollClient.defaultConfiguration) {
            self.configuration = configuration
        }

        func setConfiguration(_ factory: @escaping @Sendable () -> URLSessionConfiguration) {
            configuration = factory
        }

        /// An ephemeral session owns its connection pool, so building one per request meant
        /// a fresh TCP+TLS handshake for each topic opened in the history window, and the
        /// `finishTasksAndInvalidate` at the end threw away the keep-alive connection the
        /// next poll would have reused.
        func makeSession() -> URLSession {
            if let session { return session }
            let created = URLSession(configuration: configuration())
            session = created
            return created
        }

        /// Drops the shared session so the next poll builds one from the current
        /// `configuration`; tests swap that, the app itself keeps one session for its life.
        func reset() {
            let old = session
            session = nil
            old?.finishTasksAndInvalidate()
        }
    }

    static let sessionPool = SessionPool()

    /// Test hook: swaps the session configuration factory and drops the cached session.
    static func setSessionConfiguration(_ factory: @escaping @Sendable () -> URLSessionConfiguration) async {
        await sessionPool.setConfiguration(factory)
        await sessionPool.reset()
    }

    /// Test/teardown hook: drops the cached session and restores the production factory.
    static func resetSession() async {
        await sessionPool.setConfiguration(defaultConfiguration)
        await sessionPool.reset()
    }

    enum PollError: Error, LocalizedError {
        case http(status: Int, retryAfter: TimeInterval?)
        case network(Error)

        var errorDescription: String? {
            switch self {
            case .http(let status, let retryAfter):
                if let retryAfter {
                    return L10n.format("服务器返回 %1$d（限速），%2$d 秒后可重试", status, Int(retryAfter))
                }
                return L10n.format("服务器返回 %1$d", status)
            case .network(let error):
                return L10n.format("网络错误：%@", error.localizedDescription)
            }
        }

        /// If this error is a rate limit (429), the suggested retry delay.
        var retryAfter: TimeInterval? {
            if case .http(429, let retryAfter) = self { return retryAfter }
            return nil
        }
    }

    struct PollResult {
        /// Number of regular message events received.
        var messageCount = 0
        /// Number of message_delete / message_clear events received.
        var actionEventCount = 0
        /// The newest event seen, message or action — what the `since` cursor advances to.
        var newestEvent: NtfyMessage?
        /// The server capped the replay (`X-Messages-Truncated`) and dropped its OLDER
        /// rows to fit. Advancing a sync cursor past a truncated replay would orphan
        /// those rows, so the caller must not treat the newest event as fully caught up.
        var truncated = false
    }

    /// Streams the poll response and hands the replayed events over in batches. A full sync
    /// can carry tens of thousands of rows, and one write transaction per row would keep the
    /// store's serial queue busy — and the UI waiting on it — for minutes. `onEvents` receives
    /// messages and delete/clear events in the order the server sent them, so an event still
    /// lands after the message it targets.
    static func poll(
        serverURL: String,
        topic: String,
        since: String,
        authToken: String?,
        onEvents: @escaping @Sendable ([NtfyMessage]) async throws -> Void
    ) async throws -> PollResult {
        guard var components = URLComponents(string: serverURL) else {
            throw PollError.network(URLError(.badURL))
        }
        components.path = "/\(topic)/json"
        components.queryItems = [
            URLQueryItem(name: "poll", value: "1"),
            URLQueryItem(name: "since", value: since),
        ]
        guard let url = components.url else {
            throw PollError.network(URLError(.badURL))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        // Large full-history replays can take a while; only the time-to-first-byte is bounded.
        request.timeoutInterval = 120
        if let authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let session = await Self.sessionPool.makeSession()

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw PollError.network(error)
        }

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .map { HTTPRetryAfter.delay(forHeaderValue: $0) }
            throw PollError.http(status: httpResponse.statusCode, retryAfter: retryAfter)
        }

        // Read before the body streams: the header is set ahead of the first row.
        let truncated = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "X-Messages-Truncated") == "1"

        var result = PollResult()
        var batch: [NtfyMessage] = []
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8) else { continue }
            let message: NtfyMessage
            do {
                message = try decoder.decode(NtfyMessage.self, from: data)
            } catch {
                Log.error("Poll: failed to decode line: \(error)")
                continue
            }

            switch message.event {
            case "message":
                result.messageCount += 1
            case NtfyMessage.deleteEvent, NtfyMessage.clearEvent:
                result.actionEventCount += 1
            default:
                continue  // open / keepalive / poll_request
            }
            // Action events count too: they are cached rows like any message, so a cursor
            // that stops at the newest message keeps replaying the events behind it.
            if message.time >= (result.newestEvent?.time ?? .min) {
                result.newestEvent = message
            }
            batch.append(message)

            if batch.count >= Self.eventBatchSize {
                try await onEvents(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            try await onEvents(batch)
        }
        result.truncated = truncated
        return result
    }
}
