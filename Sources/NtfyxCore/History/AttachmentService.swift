import Foundation
import CryptoKit

/// Downloads message attachments into a local cache and hands them to the
/// default application. The auth token is sent only when the attachment URL
/// lives on the same host as the subscription, so private topics work without
/// leaking the token to third-party hosts.
enum AttachmentService {
    enum AttachmentError: LocalizedError, Equatable {
        case invalidURL
        case http(status: Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "附件地址无效"
            case .http(let status): return "HTTP \(status)"
            }
        }
    }

    /// ~/Library/Caches/ntfyx/attachments
    static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return caches.appendingPathComponent("ntfyx/attachments", isDirectory: true)
    }

    /// Downloads the attachment (reusing a cached copy when present) and returns the local file URL.
    /// The auth token is only sent when the attachment URL shares the server's host, so
    /// externally hosted attachments never carry it.
    @discardableResult
    static func download(
        attachment: NtfyMessage.NtfyAttachment,
        serverURL: String,
        authToken: String?,
        to directory: URL? = nil,
        session: URLSession = .shared
    ) async throws -> URL {
        guard let url = URL(string: attachment.url) else { throw AttachmentError.invalidURL }
        let dir = directory ?? cacheDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(cachedFileName(for: attachment, url: url))
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if let token = authToken, !token.isEmpty,
           URL(string: serverURL)?.host?.lowercased() == url.host?.lowercased() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AttachmentError.http(status: http.statusCode)
        }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private static func cachedFileName(for attachment: NtfyMessage.NtfyAttachment, url: URL) -> String {
        // Content-addressed by the (unique, signed) attachment URL so replays don't
        // collide with same-named files from other messages.
        let hash = SHA256.hash(data: Data(attachment.url.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        // No dots survive sanitization, so a crafted name can never make a relative path;
        // the extension is re-derived from the URL (or the name) and re-validated.
        let safeName = attachment.name
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "_" }
            .joined()
            .prefix(64)
        let rawExt = url.pathExtension.isEmpty ? (attachment.name as NSString).pathExtension : url.pathExtension
        let safeExt = rawExt
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .prefix(10)
        return safeExt.isEmpty ? "\(hash)-\(safeName)" : "\(hash)-\(safeName).\(safeExt)"
    }
}
