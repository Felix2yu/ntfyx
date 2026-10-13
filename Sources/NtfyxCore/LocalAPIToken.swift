import Foundation
import Security

/// The per-machine bearer token that guards the local notification API.
///
/// The listener is only reachable from loopback, but loopback alone does not identify the
/// caller: any local process — and, through a form/navigation POST, any web page the user
/// has open — could otherwise make ntfyx display arbitrary notifications. A 256-bit random
/// token in a `0600` file means callers must already run as this user and read the file;
/// browser-originated requests cannot attach the `Authorization` header cross-origin.
enum LocalAPIToken {
    /// File name inside `~/Library/Application Support/ntfyx/`.
    static let fileName = "local-token"

    /// 256-bit tokens, hex-encoded.
    static let byteCount = 32
    static let minLength = 32

    enum TokenError: Error, LocalizedError {
        case generateFailed(Int32)
        case writeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .generateFailed(let status):
                return "无法生成本地 API 令牌（SecRandomCopyBytes 返回 \(status)）"
            case .writeFailed(let error):
                return "无法写入本地 API 令牌文件：\(error.localizedDescription)"
            }
        }
    }

    /// `~/Library/Application Support/ntfyx/local-token`.
    static var tokenURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("ntfyx", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Returns the existing token, or generates one and writes it with `0600` permissions.
    /// Tokens shorter than `minLength` (files from old debug builds) are rotated.
    static func load() throws -> String {
        let url = tokenURL
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let token = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.count >= minLength, token.allSatisfy(\.isHexDigit) {
                // Defense in depth: tighten bits if the file was restored with looser ones.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path
                )
                return token
            }
        }
        return try create(at: url)
    }

    private static func create(at url: URL) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw TokenError.generateFailed(status) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path
            )
            try token.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path
            )
        } catch {
            throw TokenError.writeFailed(error)
        }
        return token
    }
}
