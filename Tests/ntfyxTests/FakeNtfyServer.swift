import Foundation
@testable import ntfyx

/// In-process ntfy server shaped like the fork's message cache: one append-only table per topic,
/// polled oldest first, where `message_delete` and `message_clear` are stored as events of their
/// own instead of rewriting the row they act on.
///
/// The details that only matter because the client depends on them:
/// - `since=<message id>` replays the rows inserted *after* that one (`id > COALESCE((SELECT id
///   FROM messages WHERE mid = ?), 0)`), so an action event lands after its target.
/// - Deleting a message leaves the target row in the cache (`TestServer_DeleteMessage` polls back
///   both the message and the delete event); the client's tombstone is what hides it again.
/// - `ForJSON` drops `sequence_id` when it repeats the message id, so a plain publish comes back
///   without one and the client addresses it by message id.
/// - `GET /v1/topics` is `SELECT topic FROM messages GROUP BY topic`, so a topic stays listed
///   while *any* row survives — including the delete events left behind by cleaning up.
final class FakeNtfyServer: @unchecked Sendable {

    /// Deliberately unresolvable: `Route` answers every request before a DNS lookup, so the
    /// tests still run the client's real URL building and NDJSON decoding.
    static let baseURL = "https://fake.ntfy.test"

    /// One row of the cache table.
    struct Row {
        let rowID: Int
        let id: String
        let sequenceID: String
        let time: Int
        let event: String
        let topic: String
        let title: String
        let message: String

        var json: [String: Any] {
            var object: [String: Any] = ["id": id, "time": time, "event": event, "topic": topic]
            if sequenceID != id { object["sequence_id"] = sequenceID }
            if !title.isEmpty { object["title"] = title }
            if !message.isEmpty { object["message"] = message }
            return object
        }
    }

    private let lock = NSLock()
    private var table: [String: [Row]] = [:]
    private var nextRowID = 1
    private var lastTime = 0
    private var savedPollConfiguration: (@Sendable () -> URLSessionConfiguration)?
    private var servedSession: URLSession?

    // MARK: - Wiring the client up to this server

    nonisolated(unsafe) private static var _active: FakeNtfyServer?
    private static var active: FakeNtfyServer? {
        get {
            FakeNtfyServer.lock.lock()
            defer { FakeNtfyServer.lock.unlock() }
            return _active
        }
        set {
            FakeNtfyServer.lock.lock()
            defer { FakeNtfyServer.lock.unlock() }
            _active = newValue
        }
    }
    private static let lock = NSLock()

    /// Points the poll client and the action API at this server, and returns the session to hand
    /// to `MessageActionService`. Call `uninstall()` when the test is done.
    func install() -> URLSession {
        lock.lock(); defer { lock.unlock() }
        FakeNtfyServer.active = self
        savedPollConfiguration = NtfyPollClient.configuration
        NtfyPollClient.configuration = { Self.interceptingConfiguration() }
        NtfyPollClient.resetSession()

        let session = URLSession(configuration: Self.interceptingConfiguration())
        servedSession = session
        return session
    }

    func uninstall() {
        lock.lock(); defer { lock.unlock() }
        if FakeNtfyServer.active === self { FakeNtfyServer.active = nil }
        if let savedPollConfiguration {
            NtfyPollClient.configuration = savedPollConfiguration
            self.savedPollConfiguration = nil
        }
        NtfyPollClient.resetSession()
        servedSession?.finishTasksAndInvalidate()
        servedSession = nil
    }

    private static func interceptingConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Route.self]
        return config
    }

    // MARK: - Test-side inspection

    /// Rows of one topic, cache order (oldest first).
    func rows(topic: String) -> [Row] {
        lock.lock(); defer { lock.unlock() }
        return table[topic] ?? []
    }

    // MARK: - Request handling

    private struct Reply {
        let status: Int
        let contentType: String
        let data: Data
    }

    private func handle(
        method: String, url: URL, headers: [String: String], body: Data
    ) -> Reply {
        let parts = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { segment in String(segment).removingPercentEncoding ?? String(segment) }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let header: (String) -> String? = { name in
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        lock.lock(); defer { lock.unlock() }

        if parts.first == "v1" {
            if parts.count == 2, parts[1] == "topics", method == "GET" {
                return json(200, ["topics": topicsWithRows()])
            }
            if parts.count == 3, parts[1] == "topics", method == "DELETE" {
                let topic = parts[2]
                guard Self.isValidActionID(topic) else { return badRequest("invalid topic") }
                // handleTopicDelete: the whole cache entry goes, events included. Auth-enabled
                // servers demand write access; this one models `userManager == nil`, i.e. allowed.
                let purged = (table[topic] ?? []).count
                table[topic] = nil
                return json(200, ["topic": topic, "deleted_messages": purged])
            }
            return notFound(method: method, url: url)
        }

        guard let topic = parts.first, Self.isValidActionID(topic) else { return badRequest("invalid topic") }

        if parts.count == 2, parts[1] == "json", method == "GET" {
            let lines = replay(topic: topic, since: queryItem("since", in: query) ?? "")
                .map { String(decoding: dataInJSON($0.json), as: UTF8.self) }
            return Reply(
                status: 200, contentType: "application/x-ndjson",
                data: Data(lines.joined(separator: "\n").utf8)
            )
        }
        if parts.count == 1, method == "POST" || method == "PUT" {
            let row = publish(
                topic: topic,
                title: header("Title") ?? header("X-Title") ?? "",
                message: String(decoding: body, as: UTF8.self),
                sequenceID: header("X-Sequence-Id") ?? header("Sequence-Id")
            )
            return json(200, row.json)
        }
        if parts.count == 2, method == "DELETE" {
            return action(event: NtfyMessage.deleteEvent, topic: topic, pathIDs: parts[1])
        }
        if parts.count == 3, method == "GET", parts[2] == "read" || parts[2] == "clear" {
            return action(event: NtfyMessage.clearEvent, topic: topic, pathIDs: parts[1])
        }
        return notFound(method: method, url: url)
    }

    private func notFound(method: String, url: URL) -> Reply {
        Reply(
            status: 404, contentType: "application/json",
            data: dataInJSON(["error": "no such route: \(method) \(url.path)"])
        )
    }

    private func publish(
        topic: String, title: String, message: String, sequenceID: String?
    ) -> Row {
        let id = Self.newMessageID()
        return append(
            Row(
                rowID: nextRowID,
                id: id,
                // parsePublishParams: a publisher that named no sequence id is addressed by its
                // message id, which `ForJSON` then hides from the wire.
                sequenceID: sequenceID ?? id,
                time: now(),
                event: "message",
                topic: topic,
                title: title,
                message: message
            ),
            to: topic
        )
    }

    /// `handleActionMessage`: one event row per requested id, the target row untouched.
    private func action(event: String, topic: String, pathIDs: String) -> Reply {
        let ids = pathIDs.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !ids.isEmpty, ids.allSatisfy(Self.isValidActionID) else {
            return badRequest("invalid sequence id")
        }
        let events = ids.map { id in
            append(
                Row(
                    rowID: nextRowID,
                    id: Self.newMessageID(),
                    sequenceID: id,
                    time: now(),
                    event: event,
                    topic: topic,
                    title: "",
                    message: ""
                ),
                to: topic
            ).json
        }
        if events.count == 1 { return json(200, events[0]) }
        return Reply(
            status: 200, contentType: "application/json",
            data: dataInJSON(events)
        )
    }

    private func append(_ row: Row, to topic: String) -> Row {
        nextRowID += 1
        table[topic, default: []].append(row)
        return row
    }

    private func now() -> Int {
        let seconds = Int(Date().timeIntervalSince1970)
        // Replay order is insertion order, so a clock that steps backwards mid-test must not
        // reorder it while sorting the replay by time.
        lastTime = max(seconds, lastTime)
        return lastTime
    }

    /// `MessagesCapped`: rows after the `since` marker, oldest first.
    private func replay(topic: String, since: String) -> [Row] {
        let cached = table[topic] ?? []
        if since.isEmpty || since == "all" { return cached }
        if since == "none" { return [] }
        if Self.isMessageID(since) {
            guard let marker = cached.firstIndex(where: { $0.id == since }) else {
                return cached  // COALESCE(..., 0) — an unknown id replays the whole topic
            }
            return Array(cached[(marker + 1)...])
        }
        if let timestamp = Int(since) { return cached.filter { $0.time >= timestamp } }
        return cached
    }

    /// `SELECT topic FROM messages GROUP BY topic` — a topic is listed while any row of its
    /// cache entry survives, delete and clear events included.
    private func topicsWithRows() -> [String] {
        table
            .sorted { ($0.value.first?.rowID ?? 0) < ($1.value.first?.rowID ?? 0) }
            .map(\.key)
    }

    private func json(_ status: Int, _ object: Any) -> Reply {
        Reply(status: status, contentType: "application/json", data: dataInJSON(object))
    }

    private func dataInJSON(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func badRequest(_ reason: String) -> Reply {
        Reply(
            status: 400, contentType: "application/json",
            data: dataInJSON(["error": reason, "http_status": 400])
        )
    }

    private func queryItem(_ name: String, in query: [URLQueryItem]) -> String? {
        query.first { $0.name == name }?.value
    }

    /// The fork's topic and sequence id shape: `[-_A-Za-z0-9]{1,64}`.
    private static func isValidActionID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 64 else { return false }
        return id.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "-"), UInt8(ascii: "_"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"):
                return true
            default:
                return false
            }
        }
    }

    /// `model.GenerateMessageID`.
    private static func newMessageID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<12).map { _ in alphabet.randomElement()! })
    }

    /// `model.ValidMessageID`: 12 alphanumeric characters, which is also how a `since`
    /// parameter is told apart from a timestamp.
    private static func isMessageID(_ value: String) -> Bool {
        guard value.utf8.count == 12 else { return false }
        return value.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"):
                return true
            default:
                return false
            }
        }
    }

    /// Answers every request from the owning server instance.
    private final class Route: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let server = FakeNtfyServer.active, let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            let reply = server.handle(
                method: request.httpMethod ?? "GET",
                url: url,
                headers: request.allHTTPHeaderFields ?? [:],
                body: Self.body(of: request)
            )
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": reply.contentType]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !reply.data.isEmpty {
                client?.urlProtocol(self, didLoad: reply.data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// URLSession hands the publish body over as a stream, not as `httpBody`.
        private static func body(of request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }
}
