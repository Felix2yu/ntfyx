import Foundation
import AppKit

/// Why a topic lifecycle request (`/v1/topics`) did not go through.
enum TopicActionError: LocalizedError, Equatable {
    case invalidURL(String)
    case invalidResponse
    case httpStatus(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "服务器地址无效：\(url)"
        case .invalidResponse: return "服务器返回了无法识别的响应"
        case .httpStatus(let code):
            switch code {
            case 401, 403: return "无权限（HTTP \(code)）：该服务器需要写入权限才能管理主题"
            case 404: return "服务器上不存在该主题（HTTP 404）"
            default: return "服务器返回 HTTP \(code)"
            }
        case .badResponse: return "服务器返回了无法解析的主题列表"
        }
    }
}

/// Server-side message operations (delete, mark-read) plus shared URL-opening helpers.
enum MessageActionService {

    /// Sequence IDs accepted in one comma-separated path segment by the fork's
    /// `/{topic}/{id1,id2,…}/read` route.
    static let sequenceIDsPerRequest = 50

    /// The id a `/read` or `/delete` request addresses a message by: the publisher's sequence
    /// id, or the message id for messages published without one.
    /// - Returns: nil when neither id has the shape the server accepts, so that the caller can
    ///   skip the target instead of failing a whole batch.
    static func serverTargetID(sequenceID: String?, messageID: String) -> String? {
        let id = sequenceID.flatMap { $0.isEmpty ? nil : $0 } ?? messageID
        return isActionIDShape(id) ? id : nil
    }

    /// The server validates every id in the list against `[-_A-Za-z0-9]{1,64}` and rejects the
    /// entire request if one is off, so an odd id must never be handed to a batch.
    private static func isActionIDShape(_ id: String) -> Bool {
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

    /// Requests the server to delete a cached message:
    /// `DELETE {server}/{topic}/{sequence_id}` (fork supports it; upstream >= v2.16).
    /// Any failure is logged and reported through the return value — the local tombstone stays
    /// in place either way. The delete route takes a single id, so clearing a topic costs one
    /// request per message.
    /// - Returns: true when the server accepted the event (or the target is already gone).
    @discardableResult
    static func deleteOnServer(
        serverURL: String,
        topic: String,
        sequenceID: String?,
        messageID: String,
        authToken: String?,
        session: URLSession = .shared
    ) async -> Bool {
        guard let targetID = serverTargetID(sequenceID: sequenceID, messageID: messageID) else {
            return false
        }

        guard let url = URL(string: "\(serverURL)/\(topic)/\(targetID)") else {
            Log.error("Server delete: invalid URL for \(topic)/\(targetID)")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        if let authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                Log.error("Server delete failed for \(topic)/\(targetID): no HTTP response")
                return false
            }
            switch httpResponse.statusCode {
            case 200...299:
                Log.info("Server delete ok: \(topic)/\(targetID)")
            case 404:
                // Already gone server-side — fine.
                Log.info("Server delete: \(topic)/\(targetID) not found (already gone)")
            default:
                Log.error("Server delete failed for \(topic)/\(targetID): HTTP \(httpResponse.statusCode)")
                return false
            }
            return true
        } catch {
            Log.error("Server delete failed for \(topic)/\(targetID): \(error.localizedDescription)")
            return false
        }
    }

    /// Deletes every listed message on the server, oldest request last is irrelevant — the ids
    /// arrive newest-first from the caller. Stops at the first rejection: that usually means
    /// offline or no write permission, and pushing on would just spend the rate-limit budget.
    /// - Returns: how many targets the server accepted.
    @discardableResult
    static func deleteAllOnServer(
        serverURL: String,
        topic: String,
        targets: [(sequenceID: String?, messageID: String)],
        authToken: String?,
        session: URLSession = .shared
    ) async -> Int {
        var synced = 0
        for target in targets {
            let ok = await deleteOnServer(
                serverURL: serverURL, topic: topic,
                sequenceID: target.sequenceID, messageID: target.messageID,
                authToken: authToken, session: session
            )
            guard ok else {
                Log.info("Server clear for \(topic) stopped after \(synced)/\(targets.count)")
                return synced
            }
            synced += 1
        }
        return synced
    }

    /// Requests the server to mark a cached message as read:
    /// `GET {server}/{topic}/{sequence_id}/read` (alias of `/clear`). The server turns this
    /// into a `message_clear` broadcast, so every other device follows along.
    /// Failures are logged and reported through the return value — the local read state is
    /// already applied, so an offline or read-only client simply stays local.
    /// - Returns: true when the server accepted the event (or the target is already gone).
    @discardableResult
    static func markReadOnServer(
        serverURL: String,
        topic: String,
        sequenceID: String?,
        messageID: String,
        authToken: String?,
        session: URLSession = .shared
    ) async -> Bool {
        guard let targetID = serverTargetID(sequenceID: sequenceID, messageID: messageID) else {
            return false
        }
        return await markReadChunkOnServer(
            serverURL: serverURL, topic: topic, ids: [targetID],
            authToken: authToken, session: session
        )
    }

    /// Marks a batch of messages read on the server. One request carries up to
    /// `sequenceIDsPerRequest` ids, so a topic with hundreds of unreads is a handful of
    /// requests instead of hundreds.
    ///
    /// The server still publishes one `message_clear` per id and each one spends a unit of the
    /// visitor's message budget, so a chunk can fail partway through having already broadcast
    /// some of its ids; the count returned is therefore the ids in the chunks that came back
    /// clean, i.e. a lower bound of what actually converged.
    /// Stops after the first rejected chunk rather than burning requests on a rate-limited
    /// or read-only connection.
    /// - Returns: how many targets the server accepted.
    @discardableResult
    static func markAllReadOnServer(
        serverURL: String,
        topic: String,
        targets: [(sequenceID: String?, messageID: String)],
        authToken: String?,
        session: URLSession = .shared
    ) async -> Int {
        var ids: [String] = []
        var seen: Set<String> = []
        for target in targets {
            guard let id = serverTargetID(sequenceID: target.sequenceID, messageID: target.messageID),
                  seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        guard !ids.isEmpty else { return 0 }

        var synced = 0
        var index = 0
        while index < ids.count {
            let chunk = Array(ids[index..<min(index + Self.sequenceIDsPerRequest, ids.count)])
            let ok = await markReadChunkOnServer(
                serverURL: serverURL, topic: topic, ids: chunk,
                authToken: authToken, session: session
            )
            guard ok else {
                Log.info("Server mark-all-read for \(topic) stopped after \(synced)/\(ids.count)")
                return synced
            }
            synced += chunk.count
            index += chunk.count
        }
        return synced
    }

    /// `GET {server}/{topic}/{id1,id2,…}/read` — a single id is the one-element case.
    private static func markReadChunkOnServer(
        serverURL: String,
        topic: String,
        ids: [String],
        authToken: String?,
        session: URLSession
    ) async -> Bool {
        let joined = ids.joined(separator: ",")
        guard let url = URL(string: "\(serverURL)/\(topic)/\(joined)/read") else {
            Log.error("Server mark-read: invalid URL for \(topic)/\(joined)")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        if let authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                Log.error("Server mark-read failed for \(topic)/\(joined): no HTTP response")
                return false
            }
            switch httpResponse.statusCode {
            case 200...299, 404:
                // 404: the topic is gone server-side, which is the state we wanted anyway.
                Log.info("Server mark-read ok: \(topic)/\(joined) (\(ids.count) id(s), HTTP \(httpResponse.statusCode))")
                return true
            default:
                Log.error("Server mark-read failed for \(topic)/\(joined): HTTP \(httpResponse.statusCode)")
                return false
            }
        } catch {
            Log.error("Server mark-read failed for \(topic)/\(joined): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Message actions (view / http / copy)

    /// Executes an ntfy message action from the history UI.
    /// - Parameters:
    ///   - serverURL: base URL of the server the message came from — allow-lists are
    ///     configured per server, and the same topic name can exist on several.
    ///   - serverConfig: that server's config, resolved by the caller on the main actor.
    static func execute(
        action: NtfyMessage.NtfyAction,
        serverURL: String,
        serverConfig: ServerConfig?
    ) {
        switch action.action {
        case "view":
            guard let urlString = action.url, let url = URL(string: urlString) else { return }
            openSecurely(url, serverBaseURL: serverURL, serverConfig: serverConfig)
        case "http":
            guard let urlString = action.url, let url = URL(string: urlString) else { return }
            executeHTTP(url: url, method: action.method ?? "POST", headers: action.headers, body: action.body)
        case "copy":
            let text = action.body ?? action.url ?? ""
            if !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        default:
            // "broadcast" is Android-only; script actions are config-only by design.
            Log.info("Unsupported action type '\(action.action)' in history UI")
        }
    }

    /// Opens a URL after validating scheme/domain against the server config —
    /// same rules as NotificationManager.openUrlSecurely. The caller (main actor)
    /// resolves the config and passes it in; this stateless helper never reads the
    /// configuration source itself.
    static func openSecurely(_ url: URL, serverBaseURL: String?, serverConfig: ServerConfig?) {
        let schemeAllowed = serverConfig?.isSchemeAllowed(url) ?? ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        guard schemeAllowed else {
            let allowed = serverConfig?.effectiveAllowedSchemes ?? ["http", "https"]
            Log.info("Refusing to open URL with untrusted scheme: \(url.scheme ?? "nil") (\(url.absoluteString)). Allowed: \(allowed)")
            return
        }

        guard serverConfig?.isDomainAllowed(url) ?? true else {
            let allowed = serverConfig?.allowedDomains ?? []
            Log.info("Refusing to open URL with untrusted domain: \(url.host ?? "nil") (\(url.absoluteString)). Allowed: \(allowed)")
            return
        }

        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    private static func executeHTTP(url: URL, method: String, headers: [String: String]?, body: String?) {
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            request.httpBody = body.data(using: .utf8)
        }
        Log.info("Executing HTTP \(method) action: \(url.absoluteString)")

        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse {
                    Log.info("HTTP action completed with status: \(httpResponse.statusCode)")
                }
            } catch {
                Log.error("HTTP action failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Topic lifecycle (/v1/topics)

    /// Topic ids the server currently has cached messages for (`GET /v1/topics`).
    /// An empty list is legitimate — every message expired or the topic was retired.
    static func fetchServerTopics(
        serverURL: String,
        authToken: String?,
        session: URLSession = .shared
    ) async throws -> [String] {
        let response: ServerTopicsResponse = try await request(
            "GET", "\(serverURL)/v1/topics", authToken: authToken, session: session
        )
        return response.topics
    }

    /// Retires a topic on the server (`DELETE /v1/topics/{topic}`): every cached message and
    /// attachment of that topic is purged, so it disappears for all devices until something is
    /// published again. Persisted server-side topic configuration is left alone.
    /// - Returns: how many cached messages the server removed.
    @discardableResult
    static func retireTopic(
        serverURL: String,
        topic: String,
        authToken: String?,
        session: URLSession = .shared
    ) async throws -> Int {
        let escaped = topic.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? topic
        let response: TopicRetireResponse = try await request(
            "DELETE", "\(serverURL)/v1/topics/\(escaped)", authToken: authToken, session: session
        )
        Log.info("Retired server topic \(serverURL)/\(topic): \(response.deletedMessages) message(s) purged")
        return response.deletedMessages
    }

    struct ServerTopicsResponse: Decodable {
        let topics: [String]
    }

    struct TopicRetireResponse: Decodable {
        let deletedMessages: Int

        private enum CodingKeys: String, CodingKey {
            case deletedMessages = "deleted_messages"
        }
    }

    /// Performs a topic-lifecycle request and decodes the JSON body. A non-JSON answer or any
    /// status outside 200…299 becomes a `TopicActionError`, so the UI can name the server's
    /// objection instead of failing silently.
    private static func request<T: Decodable>(
        _ method: String,
        _ urlString: String,
        authToken: String?,
        session: URLSession
    ) async throws -> T {
        guard let url = URL(string: urlString) else {
            throw TopicActionError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TopicActionError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw TopicActionError.httpStatus(httpResponse.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TopicActionError.badResponse
        }
    }

    // MARK: - Formatting helpers

    /// Human-readable timestamp: relative time for recent messages, absolute date otherwise.
    static func formattedTime(_ unixSeconds: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "刚刚"
        } else if interval < 24 * 3600 {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        } else if interval < 365 * 24 * 3600 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 HH:mm"
            return formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy年M月d日"
            return formatter.string(from: date)
        }
    }

    /// Human-readable file size.
    static func formattedFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
