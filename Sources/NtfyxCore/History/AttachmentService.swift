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

    /// Bounds the on-disk attachment cache (audit D2). `0` disables that limit.
    struct AttachmentCachePolicy: Sendable, Equatable {
        var maxBytes: Int
        var maxFiles: Int

        /// Trimming removes LRU files until 80% of each limit, so a download
        /// that just crossed the cap does not get trimmed again on the next one.
        static let hysteresis = 0.8

        static let standard = AttachmentCachePolicy(
            maxBytes: 200 * 1_024 * 1_024,
            maxFiles: 500
        )
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
    ///
    /// The download streams into a same-directory temporary file (large attachments never
    /// sit fully in memory) and atomically moves into place; on any failure or cancellation
    /// the temporary file is removed. After a new file lands, the cache is LRU-trimmed.
    @discardableResult
    static func download(
        attachment: NtfyMessage.NtfyAttachment,
        serverURL: String,
        authToken: String?,
        to directory: URL? = nil,
        policy: AttachmentCachePolicy = .standard,
        session: URLSession = .shared
    ) async throws -> URL {
        guard let url = URL(string: attachment.url) else { throw AttachmentError.invalidURL }
        let dir = directory ?? cacheDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(cachedFileName(for: attachment, url: url))
        if FileManager.default.fileExists(atPath: destination.path) {
            // Cache hit: refresh mtime so LRU ordering treats this as recent use.
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: destination.path
            )
            return destination
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if let token = authToken, !token.isEmpty,
           URL(string: serverURL)?.host?.lowercased() == url.host?.lowercased() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // No temp file exists yet: failures leave the directory untouched.
            throw AttachmentError.http(status: http.statusCode)
        }

        let temporary = dir.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString.prefix(8))"
        )
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            // AsyncBytes yields UInt8; coalesce into 64 KB flushes so a large
            // attachment costs one write per block, not one per byte.
            var buffer = Data()
            buffer.reserveCapacity(64 * 1_024)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 64 * 1_024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }
            try handle.close()
        } catch {
            // Cancellation, network drop, disk error: never leave a partial file behind.
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        do {
            // Same directory, so the rename is atomic and can never cross volumes.
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            // A concurrent download of the same content-addressed URL may have won
            // the race; the existing file has identical bytes, so use it.
            try? FileManager.default.removeItem(at: temporary)
            guard FileManager.default.fileExists(atPath: destination.path) else { throw error }
            return destination
        }

        try? trimCache(directory: dir, policy: policy)
        return destination
    }

    /// Deletes least-recently-used files (by mtime) until the cache is at 80% of
    /// each policy limit. Newly downloaded files are never passed in here mid-write:
    /// only finished files are enumerated, and `.tmp` partials are ignored.
    static func trimCache(directory: URL, policy: AttachmentCachePolicy) throws {
        // A not-yet-created cache directory simply has nothing to trim.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path, isDirectory: &isDirectory
        ), isDirectory.boolValue else { return }

        let urls = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") }
            .map { directory.appendingPathComponent($0) }
        var entries: [(url: URL, size: Int, modificationDate: Date)] = []
        entries.reserveCapacity(urls.count)
        var totalBytes = 0
        for url in urls {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey
            ])
            guard values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            entries.append((url, size, values.contentModificationDate ?? .distantPast))
            totalBytes += size
        }

        let byteTarget = policy.maxBytes > 0
            ? Int(Double(policy.maxBytes) * AttachmentCachePolicy.hysteresis)
            : Int.max
        let fileTarget = policy.maxFiles > 0
            ? Int(Double(policy.maxFiles) * AttachmentCachePolicy.hysteresis)
            : Int.max
        guard totalBytes > byteTarget || entries.count > fileTarget else { return }

        var oldestFirst = entries.sorted { $0.modificationDate < $1.modificationDate }
        while (totalBytes > byteTarget || oldestFirst.count > fileTarget), !oldestFirst.isEmpty {
            let victim = oldestFirst.removeFirst()
            try? FileManager.default.removeItem(at: victim.url)
            totalBytes -= victim.size
        }
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
