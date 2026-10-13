import Foundation

/// Live probes for the Settings form, run against the *edited* (possibly unsaved)
/// server entry so a URL, token or topic can be verified before saving.
enum ConnectivityTest {

    enum Outcome: Equatable {
        case serverReachable(version: String?)
        case tokenRejected
        case unreachable(reason: String)
        case published
        case writeRejected(status: Int)
    }

    /// `GET {server}/json` is unauthenticated and proves reachability, TLS and the
    /// proxy path; when a token is set it is then checked against the first
    /// configured topic via a poll (401/403 means the token is wrong or missing).
    static func testConnection(
        serverURL: String,
        token: String?,
        topic: String?,
        session: URLSession = .shared
    ) async -> Outcome {
        let base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard base.hasPrefix("http"), URL(string: base) != nil else {
            return .unreachable(reason: "地址无效（需 http/https）")
        }

        var infoRequest = URLRequest(url: URL(string: "\(base)/json")!)
        infoRequest.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: infoRequest),
              let http = response as? HTTPURLResponse else {
            return .unreachable(reason: "无法连接服务器")
        }
        guard http.statusCode == 200 else {
            return .unreachable(reason: "HTTP \(http.statusCode)")
        }
        let version = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? String

        if let token, !token.isEmpty, let topic, !topic.isEmpty {
            var pollRequest = URLRequest(url: URL(string: "\(base)/\(topic)/json?poll=1&since=1")!)
            pollRequest.timeoutInterval = 15
            pollRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (pollResponse) = try? await session.data(for: pollRequest),
                  let pollHTTP = pollResponse.1 as? HTTPURLResponse else {
                return .serverReachable(version: version)  // poll unreachable — report what we know
            }
            if pollHTTP.statusCode == 401 || pollHTTP.statusCode == 403 {
                return .tokenRejected
            }
        }
        return .serverReachable(version: version)
    }

    /// Publishes one test message so the write permission (and, for subscribed
    /// topics, the whole banner pipeline) can be checked end to end.
    static func sendTestNotification(
        serverURL: String,
        topic: String,
        token: String?,
        session: URLSession = .shared
    ) async -> Outcome {
        let base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(base)/\(trimmedTopic)") else {
            return .unreachable(reason: "地址无效")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        // HTTP headers must be ASCII and ntfy does not URL-decode Title, so the
        // Chinese text lives in the body; a non-ASCII header is silently dropped.
        request.setValue("test \(trimmedTopic)", forHTTPHeaderField: "Title")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = "来自 ntfyx 设置页的测试消息 \(formatter.string(from: Date()))".data(using: .utf8)

        guard let (response) = try? await session.data(for: request),
              let http = response.1 as? HTTPURLResponse else {
            return .unreachable(reason: "无法连接服务器")
        }
        guard (200...299).contains(http.statusCode) else {
            return .writeRejected(status: http.statusCode)
        }
        return .published
    }
}
