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
    nonisolated(unsafe) static var configuration: @Sendable () -> URLSessionConfiguration = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 3600
        return config
    }

    nonisolated(unsafe) private static var _session: URLSession?
    private static let sessionLock = NSLock()

    /// One session for every poll. An ephemeral session owns its connection pool, so building
    /// one per request meant a fresh TCP+TLS handshake for each topic opened in the history
    /// window, and the `finishTasksAndInvalidate` at the end threw away the keep-alive
    /// connection the next poll would have reused.
    private static func session() -> URLSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let existing = _session { return existing }
        let created = URLSession(configuration: configuration())
        _session = created
        return created
    }

    /// Drops the shared session so the next poll builds one from the current `configuration`;
    /// tests swap that, the app itself keeps one session for its whole life.
    static func resetSession() {
        sessionLock.lock()
        let old = _session
        _session = nil
        sessionLock.unlock()
        old?.finishTasksAndInvalidate()
    }

    enum PollError: Error, LocalizedError {
        case http(status: Int, retryAfter: TimeInterval?)
        case network(Error)

        var errorDescription: String? {
            switch self {
            case .http(let status, let retryAfter):
                if let retryAfter {
                    return "服务器返回 \(status)（限速），\(Int(retryAfter)) 秒后可重试"
                }
                return "服务器返回 \(status)"
            case .network(let error):
                return "网络错误：\(error.localizedDescription)"
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
        /// The message with the highest `time` seen (used to advance sync state).
        var newestMessage: NtfyMessage?
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

        let session = Self.session()

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw PollError.network(error)
        }

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .map { parseRetryAfter($0) }
            throw PollError.http(status: httpResponse.statusCode, retryAfter: retryAfter)
        }

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
                if message.time >= (result.newestMessage?.time ?? .min) {
                    result.newestMessage = message
                }
                batch.append(message)
            case NtfyMessage.deleteEvent, NtfyMessage.clearEvent:
                result.actionEventCount += 1
                batch.append(message)
            default:
                continue  // open / keepalive / poll_request
            }

            if batch.count >= Self.eventBatchSize {
                try await onEvents(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            try await onEvents(batch)
        }
        return result
    }

    /// Parses Retry-After (seconds or HTTP date). Mirrors NtfyClient.parseRetryAfter.
    static func parseRetryAfter(_ value: String) -> TimeInterval {
        if let seconds = TimeInterval(value) {
            return max(seconds, 1.0)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return max(date.timeIntervalSinceNow, 1.0)
            }
        }
        return 30.0
    }
}
