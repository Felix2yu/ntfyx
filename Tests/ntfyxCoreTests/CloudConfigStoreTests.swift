import XCTest
import Yams
@testable import NtfyxCore

/// Locked mutable state for @Sendable test seams.
private final class NSLockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// The iCloud Drive file itself: reading a placeholder that has not been downloaded,
/// refusing a format this build cannot write back, and recognising the conflict copies the
/// daemon leaves behind. Everything here runs against a temporary folder — the iCloud branch
/// only differs by root path.
final class CloudConfigStoreTests: XCTestCase {
    private let url = "https://a.example"

    private var directory: URL!
    private var store: CloudConfigStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ntfyx-sync-\(UUID().uuidString)")
        store = CloudConfigStore(directoryOverride: directory.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sampleDocument() -> SyncDocument {
        SyncDocument(servers: [
            SyncServer(url: url, token: "tk", topics: [
                SyncTopic(name: "alerts", iconSymbol: "bell"),
                SyncTopic(name: "builds"),
            ]),
        ]).canonicalized
    }

    // MARK: - Paths

    func testOverrideDirectoryIsUsedAsIs() {
        XCTAssertEqual(store.rootDirectory, directory.path)
        XCTAssertFalse(store.usesICloudDrive)
    }

    func testiCloudDriveBranchAppendsTheAppFolder() {
        let cloudStore = CloudConfigStore(iCloudDocsDirectory: directory.appendingPathComponent("cloud").path)
        XCTAssertTrue(cloudStore.usesICloudDrive)
        XCTAssertTrue(cloudStore.rootDirectory.hasSuffix("cloud/ntfyx"))
    }

    func testDefaultRootIsICloudDrive() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/ntfyx").path
        XCTAssertEqual(CloudConfigStore().rootDirectory, expected)
    }

    func testMissingiCloudDriveFolderIsReportedAsSuch() {
        let absent = CloudConfigStore(iCloudDocsDirectory: directory.appendingPathComponent("absent").path)
        XCTAssertThrowsError(try absent.prepare()) { error in
            guard case ConfigSyncError.iCloudDriveDisabled = error else {
                return XCTFail("应识别为 iCloud Drive 未开启，实际为 \(error)")
            }
        }
    }

    // MARK: - Read and write

    func testReadBeforeTheFileExistsReturnsNil() throws {
        XCTAssertNil(try store.readCloud())
    }

    func testWriteThenReadRoundTrips() throws {
        try store.prepare()
        let document = sampleDocument()
        try store.write(document)

        XCTAssertEqual(try store.readCloud(), document)
        XCTAssertEqual(try store.readCloud()?.serverIndex[url]?.topics.map(\.name), ["alerts", "builds"])
    }

    func testWrittenFileNeverContainsAToken() throws {
        // The sample carries a token the way an in-memory document can while merging a v1
        // cloud file; the bytes on disk must be token-free regardless.
        try store.prepare()
        try store.write(sampleDocument())
        let text = try String(contentsOf: store.cloudFileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("tk"))
        XCTAssertFalse(text.contains("token"))
        XCTAssertEqual(try store.readCloud()?.serverIndex[url]?.token, nil)
        let rawVersion = try YAMLDecoder().decode(SyncDocument.self, from: text).version
        XCTAssertEqual(rawVersion, 2)
    }

    func testV1FileStillDecodesForOneTimeKeychainBackfill() throws {
        let v1 = """
        version: 1
        servers:
          - url: \(url)
            token: v1-secret
            topics:
              - name: alerts
        """
        let decoded = try CloudConfigStore.decode(v1)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.serverIndex[url]?.token, "v1-secret", "v1 令牌临时可读，供一次性回填钥匙串")

        // Re-encoding upgrades to v2 and drops the token.
        let reencoded = try CloudConfigStore.encoded(decoded)
        XCTAssertTrue(reencoded.contains("version: 2"))
        XCTAssertFalse(reencoded.contains("v1-secret"))
        XCTAssertFalse(reencoded.contains("token"))
        let reread = try CloudConfigStore.decode(reencoded)
        XCTAssertNil(reread.serverIndex[url]?.token)
    }

    func testFileHeaderStatesTokensAreKeptInKeychain() throws {
        try store.prepare()
        try store.write(sampleDocument())
        let text = try String(contentsOf: store.cloudFileURL, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# ntfyx 同步配置"))
        XCTAssertTrue(text.contains("不含服务器令牌"))
        XCTAssertTrue(text.contains("钥匙串"))
    }

    func testRewritingTheSameDocumentKeepsTheContents() throws {
        try store.prepare()
        let document = sampleDocument()
        try store.write(document)
        try store.write(document)

        XCTAssertEqual(try store.readCloud(), document)
    }

    func testEncodingIsByteStableForTheSameDocument() throws {
        XCTAssertEqual(try CloudConfigStore.encoded(sampleDocument()),
                       try CloudConfigStore.encoded(sampleDocument()))
    }

    func testYamlRoundTripDistinguishesFalseFromAbsent() throws {
        try store.prepare()
        let document = SyncDocument(servers: [
            SyncServer(url: url, topics: [SyncTopic(name: "alerts", silent: false, clickUrl: .disabled)]),
            SyncServer(url: "https://b.example", topics: [SyncTopic(name: "builds")]),
        ])
        try store.write(document)

        let read = try store.readCloud()
        XCTAssertEqual(read?.serverIndex[url]?.topicIndex["alerts"]?.silent, false, "silent: false 不能读成缺省")
        XCTAssertEqual(read?.serverIndex[url]?.topicIndex["alerts"]?.clickUrl, .disabled)
        XCTAssertEqual(read?.servers.map(\.url), [url, "https://b.example"])
    }

    func testNewerFormatVersionRefusesToParse() {
        XCTAssertThrowsError(try CloudConfigStore.decode("version: 99\nservers: []")) { error in
            guard case ConfigSyncError.unsupportedVersion(99) = error else {
                return XCTFail("应拒绝更高版本，实际为 \(error)")
            }
        }
    }

    func testCorruptedYamlIsReportedAsSuch() {
        XCTAssertThrowsError(try CloudConfigStore.decode("version: [oops\n")) { error in
            guard case ConfigSyncError.cloudCorrupted = error else {
                return XCTFail("坏 YAML 应报解析错误，实际为 \(error)")
            }
        }
    }

    // MARK: - Conflict versions (NSFileVersion seam)

    private func writeStrayFile(named name: String, contents: String = "servers: []\n") throws {
        try contents.write(toFile: directory.appendingPathComponent(name).path, atomically: true, encoding: .utf8)
    }

    func testConflictCopiesComeFromTheInjectedVersionLister() throws {
        try store.prepare()
        try store.write(sampleDocument())
        let v1 = directory.appendingPathComponent("config (a conflict).yml")
        let v2 = directory.appendingPathComponent("config (another conflict).yml")
        try writeStrayFile(named: v1.lastPathComponent)
        try writeStrayFile(named: v2.lastPathComponent)

        let liveURL = store.cloudFileURL
        store.listConflictVersions = { live in
            XCTAssertEqual(live, liveURL)
            return [v2, v1]
        }

        XCTAssertEqual(store.conflictCopies(), [v1, v2], "返回结果按路径稳定排序")
    }

    func testConflictCopiesEmptyWhenLiveFileMissing() {
        let called = NSLockBox(false)
        store.listConflictVersions = { _ in called.value = true; return [] }
        XCTAssertTrue(store.conflictCopies().isEmpty)
        XCTAssertFalse(called.value, "live 文件尚不存在时不解析冲突版本")
    }

    func testFilenameSniffingIsGone() throws {
        // Files the old string match used to call conflicts must now be invisible:
        // NSFileVersion is the only source of conflict URLs.
        try store.prepare()
        try writeStrayFile(named: "config conflicting copy 1 of Macmini.yml")
        try writeStrayFile(named: "config 冲突副本 MacBook Pro.yml")
        try writeStrayFile(named: "notes.txt")
        XCTAssertTrue(store.conflictCopies().isEmpty)
    }

    func testConflictVersionsAreRemovedWithoutTouchingTheLiveFile() throws {
        try store.prepare()
        try store.write(sampleDocument())
        let stray = directory.appendingPathComponent("config (a conflict).yml")
        try writeStrayFile(named: stray.lastPathComponent)

        let removed = NSLockBox<[(URL, URL)]>([])
        store.removeConflictVersion = { live, versionURL in
            removed.value.append((live, versionURL))
            try? FileManager.default.removeItem(at: versionURL)
        }
        store.listConflictVersions = { _ in [stray] }

        store.deleteConflictCopies(store.conflictCopies())
        XCTAssertEqual(removed.value.map(\.1), [stray])
        XCTAssertEqual(removed.value.map(\.0), [store.cloudFileURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.cloudFileURL.path))
    }

    func testUnmergeableConflictVersionStaysOnDisk() throws {
        // The engine deletes a version only after its contents reached the merged result;
        // one this build cannot read has to survive for the next pass.
        try store.prepare()
        try store.write(sampleDocument())
        let stray = directory.appendingPathComponent("config (a conflict).yml")
        try writeStrayFile(named: stray.lastPathComponent, contents: "version: 99\nservers: []\n")
        store.listConflictVersions = { _ in [stray] }

        let copy = store.conflictCopies().first
        XCTAssertEqual(copy, stray)
        XCTAssertThrowsError(try store.read(at: stray)) { error in
            guard case ConfigSyncError.unsupportedVersion(99) = error else {
                return XCTFail("应拒绝更高版本的冲突版本，实际为 \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
    }
}
