import Foundation
import Yams

public enum ConfigSyncError: Error, LocalizedError {
    case iCloudDriveDisabled
    case accessDenied(String)
    case directoryUnreachable(String)
    case cloudNotDownloaded
    case cloudUnreadable(String)
    case cloudCorrupted(String)
    case unsupportedVersion(Int)
    case cloudWriteFailed(String)
    case localWriteFailed(String)
    case keychainUnreadable

    public var errorDescription: String? {
        switch self {
        case .iCloudDriveDisabled:
            return "iCloud Drive 未开启。请在 系统设置 → Apple 账户 → iCloud 中启用，或在设置里改用一个同步文件夹。"
        case .accessDenied(let details):
            return "无法访问同步文件夹：\(details)。若是 iCloud Drive，请在 系统设置 → 隐私与安全性 → 文件与文件夹 中允许 ntfyx 访问。"
        case .directoryUnreachable(let details):
            return "无法使用同步文件夹：\(details)"
        case .cloudNotDownloaded:
            return "云端配置尚未下载到本机，稍后会自动重试。"
        case .cloudUnreadable(let details):
            return "无法读取云端配置：\(details)"
        case .cloudCorrupted(let details):
            return "云端配置无法解析：\(details)"
        case .unsupportedVersion(let version):
            return "云端配置版本 \(version) 比本机 ntfyx 支持的版本更新，已跳过同步以免写坏它。"
        case .cloudWriteFailed(let details):
            return "写入云端配置失败：\(details)"
        case .localWriteFailed(let details):
            return "写入本地配置失败：\(details)"
        case .keychainUnreadable:
            return "钥匙串读取失败，已跳过本次同步，以免把读不到的令牌当成“已删除”同步到其他设备。"
        }
    }
}

/// Where the shared configuration file lives, and how it is read and written.
///
/// iCloud Drive is the default location: a non-sandboxed app can touch
/// `~/Library/Mobile Documents/com~apple~CloudDocs` directly and the FileProvider daemon
/// carries the file to the other Macs. CloudKit would need an iCloud entitlement plus a
/// provisioning profile, which an ad-hoc signed build cannot have, so this folder is the
/// transport here. Any other folder can be used too, which doubles as the escape hatch on a
/// Mac with iCloud Drive turned off.
///
/// The only mutable state is the directory selection, behind a lock; the file coordination
/// itself is stateless. In the app this store is additionally confined to the
/// `ConfigSyncCoordinator` actor (E1) — the synchronous API stays for the one-shot CLI and
/// the tests.
public final class CloudConfigStore: @unchecked Sendable {
    static let fileName = "config.yml"
    static let folderName = "ntfyx"

    /// Written into every cloud file: the tokens it carries are the reason it must not be
    /// handed to anyone.
    static let header = [
        "# ntfyx 同步配置（由 ntfyx 生成，请勿手工编辑）",
        "# 注意：本文件包含服务器令牌，iCloud Drive 中的内容是明文。",
    ]

    private let fileManager = FileManager.default
    private let coordinator = NSFileCoordinator()

    private let settingsLock = NSLock()
    private var _directoryOverride: String?
    private let _iCloudDocsDirectory: String

    /// nil or empty means "iCloud Drive".
    var directoryOverride: String? {
        get {
            settingsLock.lock()
            defer { settingsLock.unlock() }
            return _directoryOverride
        }
        set {
            settingsLock.lock()
            _directoryOverride = newValue
            settingsLock.unlock()
        }
    }

    /// Overridable so tests can point the iCloud branch at a temporary folder.
    var iCloudDocsDirectory: String { _iCloudDocsDirectory }

    public init(directoryOverride: String? = nil, iCloudDocsDirectory: String? = nil) {
        self._directoryOverride = directoryOverride
        self._iCloudDocsDirectory = iCloudDocsDirectory ?? CloudConfigStore.defaultICloudDocsDirectory
    }

    static var defaultICloudDocsDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            .path
    }

    var usesICloudDrive: Bool {
        directoryOverride?.isEmpty != false
    }

    public var rootDirectory: String {
        if let override = directoryOverride, !override.isEmpty {
            return override
        }
        return (_iCloudDocsDirectory as NSString).appendingPathComponent(Self.folderName)
    }

    public var cloudFileURL: URL {
        URL(fileURLWithPath: rootDirectory).appendingPathComponent(Self.fileName)
    }

    // MARK: - Directory

    /// Creates the sync folder if needed and explains *why* it could not be created —
    /// "iCloud Drive is off" and "macOS refused access" need different fixes.
    func prepare() throws {
        let root = rootDirectory
        if fileManager.fileExists(atPath: root) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ConfigSyncError.directoryUnreachable("\(root) 不是文件夹")
            }
            return
        }

        if usesICloudDrive, !fileManager.fileExists(atPath: iCloudDocsDirectory) {
            throw ConfigSyncError.iCloudDriveDisabled
        }

        do {
            try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
        } catch let error as NSError {
            if error.code == NSFileWriteFileExistsError {
                throw ConfigSyncError.directoryUnreachable("\(root) 已被占用为文件")
            }
            if usesICloudDrive {
                throw ConfigSyncError.accessDenied(error.localizedDescription)
            }
            throw ConfigSyncError.directoryUnreachable(error.localizedDescription)
        }
    }

    /// Size plus modification date: FileProvider materialises a download without a
    /// filesystem event anyone can rely on, so the service polls this marker instead.
    func cloudFingerprint() -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: cloudFileURL.path) else { return nil }
        let size = (attributes[.size] as? Int) ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size):\(Int(modified))"
    }

    // MARK: - Reading

    /// nil means the cloud file is not there yet — this is the first Mac to sync.
    func readCloud() throws -> SyncDocument? {
        try read(at: cloudFileURL)
    }

    func read(at url: URL) throws -> SyncDocument? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        var document: SyncDocument?
        var readError: Error?
        var coordinationError: NSError?
        coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readable in
            do {
                document = try Self.loadContents(of: readable, fileManager: fileManager)
            } catch {
                readError = error
            }
        }
        if let readError { throw readError }
        if let coordinationError { throw ConfigSyncError.cloudUnreadable(coordinationError.localizedDescription) }
        return document
    }

    private static func loadContents(of url: URL, fileManager: FileManager) throws -> SyncDocument {
        // An evicted placeholder has no bytes to hand over. Ask iCloud for the current
        // version and treat this cycle as "nothing to merge yet" — acting on a stale or
        // missing copy is how a sync eats a subscription.
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if let status = values?.ubiquitousItemDownloadingStatus, status != .current {
            try? fileManager.startDownloadingUbiquitousItem(at: url)
            throw ConfigSyncError.cloudNotDownloaded
        }

        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigSyncError.cloudUnreadable(error.localizedDescription)
        }
        return try decode(text)
    }

    static func decode(_ text: String) throws -> SyncDocument {
        let document: SyncDocument
        do {
            document = try YAMLDecoder().decode(SyncDocument.self, from: text)
        } catch {
            throw ConfigSyncError.cloudCorrupted(error.localizedDescription)
        }
        guard document.version <= SyncDocument.currentVersion else {
            throw ConfigSyncError.unsupportedVersion(document.version)
        }
        return document
    }

    // MARK: - Writing

    func write(_ document: SyncDocument) throws {
        try prepare()
        let text = try Self.encoded(document)

        var writeError: Error?
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: cloudFileURL, options: .forReplacing, error: &coordinationError) { target in
            do {
                try text.write(to: target, atomically: true, encoding: .utf8)
                // The file holds server tokens; keep it out of other users' reach.
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            } catch {
                writeError = error
            }
        }
        if let writeError { throw ConfigSyncError.cloudWriteFailed(writeError.localizedDescription) }
        if let coordinationError { throw ConfigSyncError.cloudWriteFailed(coordinationError.localizedDescription) }
    }

    static func encoded(_ document: SyncDocument) throws -> String {
        let body: String
        do {
            body = try YAMLEncoder().encode(document.canonicalized)
        } catch {
            throw ConfigSyncError.cloudWriteFailed(error.localizedDescription)
        }
        return header.joined(separator: "\n") + "\n" + body
    }

    // MARK: - Conflict copies

    /// iCloud Drive settles concurrent writes by leaving the loser beside the file with
    /// "conflicting copy" / "冲突副本" in its name. Those carry real edits, so the merge reads
    /// them as further cloud versions, then the leftovers are removed once merged.
    public func conflictCopies() -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: rootDirectory) else { return [] }
        let root = URL(fileURLWithPath: rootDirectory)
        return names.filter { Self.isConflictCopy($0) }.sorted().map { root.appendingPathComponent($0) }
    }

    static func isConflictCopy(_ name: String) -> Bool {
        guard name != fileName, name.hasPrefix("config"), name.contains(".yml") else { return false }
        let lowered = name.lowercased()
        return lowered.contains("conflict") || name.contains("冲突副本")
    }

    func deleteConflictCopies(_ urls: [URL]) {
        for url in urls {
            try? fileManager.removeItem(at: url)
        }
    }
}
