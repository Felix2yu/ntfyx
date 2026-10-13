import XCTest
@testable import NtfyxCore

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
        XCTAssertNil(store.cloudFingerprint())
    }

    func testWriteThenReadRoundTrips() throws {
        try store.prepare()
        let document = sampleDocument()
        try store.write(document)

        XCTAssertEqual(try store.readCloud(), document)
        XCTAssertEqual(try store.readCloud()?.serverIndex[url]?.topics.map(\.name), ["alerts", "builds"])
    }

    func testFileHeaderWarnsAboutPlaintextTokens() throws {
        try store.prepare()
        try store.write(sampleDocument())
        let text = try String(contentsOf: store.cloudFileURL, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# ntfyx 同步配置"))
        XCTAssertTrue(text.contains("明文"))
    }

    func testRewritingTheSameDocumentKeepsTheContents() throws {
        // What keeps the OS-scheduled 60s poll from doing useless work is that the service
        // records the fingerprint right *after* it writes: an atomic rewrite always
        // refreshes mtime.
        try store.prepare()
        let document = sampleDocument()
        try store.write(document)
        try store.write(document)

        XCTAssertEqual(try store.readCloud(), document)
        XCTAssertNotNil(store.cloudFingerprint())
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

    // MARK: - Conflict copies

    private func writeStrayFile(named name: String) throws {
        try "servers: []".write(toFile: directory.appendingPathComponent(name).path, atomically: true, encoding: .utf8)
    }

    func testConflictCopyNamingIsRecognisedInBothLanguages() {
        let english = "config conflicting copy 1 of Macmini.yml"
        let chinese = "config 冲突副本 MacBook Pro.yml"
        XCTAssertTrue(CloudConfigStore.isConflictCopy(english))
        XCTAssertTrue(CloudConfigStore.isConflictCopy(chinese))
        XCTAssertFalse(CloudConfigStore.isConflictCopy(CloudConfigStore.fileName))
        XCTAssertFalse(CloudConfigStore.isConflictCopy("notes.txt"))
        XCTAssertFalse(CloudConfigStore.isConflictCopy("other.yml"))
    }

    func testConflictCopiesAreListedAndRemovedWithoutTouchingTheLiveFile() throws {
        try store.prepare()
        try store.write(sampleDocument())
        try writeStrayFile(named: "config conflicting copy 1 of Macmini.yml")
        try writeStrayFile(named: "config 冲突副本 MacBook Pro.yml")
        try writeStrayFile(named: "notes.txt")

        let found = store.conflictCopies().map(\.lastPathComponent).sorted()
        XCTAssertEqual(found, ["config 冲突副本 MacBook Pro.yml", "config conflicting copy 1 of Macmini.yml"].sorted())

        store.deleteConflictCopies(found.map { directory.appendingPathComponent($0) })
        XCTAssertEqual(store.conflictCopies().count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.cloudFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("notes.txt").path))
    }

    func testUnmergeableConflictCopyStaysOnDisk() throws {
        // The service deletes a copy only after its contents reached the merged result;
        // one this build cannot read has to survive for the next pass.
        try store.prepare()
        try "version: 99\nservers: []\n".write(toFile: directory.appendingPathComponent("config conflicting copy.yml").path,
                                               atomically: true, encoding: .utf8)
        let copy = store.conflictCopies().first
        XCTAssertNotNil(copy)
        XCTAssertThrowsError(try store.read(at: copy!)) { error in
            guard case ConfigSyncError.unsupportedVersion(99) = error else {
                return XCTFail("应拒绝更高版本的冲突副本，实际为 \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy!.path))
    }
}
