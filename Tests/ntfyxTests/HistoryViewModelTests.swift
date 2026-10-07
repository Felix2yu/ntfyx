import XCTest
@testable import ntfyx

// MARK: - Mock URLProtocol for server mark-read tests

/// Records the paths of intercepted mark-read requests and answers with a fixed
/// status, so cap and partial-failure behavior can be asserted without a server.
private final class MarkReadMockProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _paths: [String] = []
    nonisolated(unsafe) private static var _status = 200

    static var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }
    static func reset(status: Int) {
        lock.lock(); _paths = []; _status = status; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MarkReadMockProtocol.lock.lock()
        MarkReadMockProtocol._paths.append(MarkReadMockProtocol.requestPath(for: request))
        let status = MarkReadMockProtocol._status
        MarkReadMockProtocol.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func requestPath(for request: URLRequest) -> String {
        (request.url?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private func markReadMockSession(status: Int) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MarkReadMockProtocol.self]
    MarkReadMockProtocol.reset(status: status)
    return URLSession(configuration: config)
}

/// The database holds every catch-up message as unread, so without a global
/// "mark everything read" the user has to clear topics one by one. These tests
/// pin that markEverythingRead empties the unread counts locally for all topics
/// and publishes the mark so the other devices converge too.
@MainActor
final class HistoryViewModelTests: XCTestCase {

    private func makeMessage(id: String, topic: String, time: Int = 1_700_000_000) -> NtfyMessage {
        NtfyMessage(
            id: id, time: time, event: "message", topic: topic,
            message: "body", title: nil, priority: 3, tags: nil,
            click: nil, actions: nil, attachment: nil, contentType: nil, sequenceId: nil
        )
    }

    func testMarkEverythingReadClearsAllTopicsLocally() async throws {
        let store = try MessageStore.inMemory()
        try await store.upsert(makeMessage(id: "a1", topic: "alpha"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "a2", topic: "alpha"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "b1", topic: "beta"), serverURL: "https://s.example")

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.serverMarkReadSession = markReadMockSession(status: 200)
        try await waitUntil { vm.totalUnread == 3 }

        vm.markEverythingRead()

        try await waitUntil { vm.totalUnread == 0 }
        let counts = try await store.unreadCountsByTopic()
        XCTAssertTrue(counts.isEmpty)

        // Both topics are published to the server too, so the other devices converge.
        let syncedIDs = MarkReadMockProtocol.paths.flatMap { path in
            path.components(separatedBy: "/")[1].components(separatedBy: ",")
        }
        XCTAssertEqual(Set(syncedIDs), ["a1", "a2", "b1"])
    }

    func testMarkEverythingReadIsNoopWhenNothingUnread() async throws {
        let store = try MessageStore.inMemory()
        try await store.upsert(makeMessage(id: "a1", topic: "alpha"), serverURL: "https://s.example")
        try await store.markAllRead(serverURL: "https://s.example", topic: "alpha")

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        try await waitUntil { vm.totalUnread == 0 }

        vm.markEverythingRead()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.totalUnread, 0)
    }

    // MARK: - Mark-all-read server sync cap (audit 2.1)

    func testMarkAllReadCapsServerSyncToNewestTargets() async throws {
        let store = try MessageStore.inMemory()
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")
        let count = HistoryViewModel.serverMarkReadCap + 10
        for i in 0..<count {
            try await store.upsert(
                makeMessage(id: "msg\(i)", topic: "alpha", time: 1_700_000_000 + i),
                serverURL: ref.serverURL
            )
        }

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.serverMarkReadSession = markReadMockSession(status: 200)

        vm.markAllRead(for: ref)

        try await waitUntil { vm.serverSyncNotice != nil }
        let chunks = MarkReadMockProtocol.paths.map { $0.components(separatedBy: "/")[1] }
        // Packaged, not one request per message: the cap is 500 ids in chunks of 50.
        XCTAssertEqual(chunks.count, HistoryViewModel.serverMarkReadCap / MessageActionService.sequenceIDsPerRequest)
        XCTAssertEqual(chunks.flatMap { $0.components(separatedBy: ",") }.count, HistoryViewModel.serverMarkReadCap)
        XCTAssertTrue(chunks[0].hasPrefix("msg\(count - 1),"))  // newest first
        XCTAssertFalse(chunks.contains { $0.split(separator: ",").contains("msg0") })  // oldest stayed local-only
        XCTAssertTrue(vm.serverSyncNotice!.contains("限速保护"))

        // Locally everything is read regardless of the cap.
        let counts = try await store.unreadCountsByTopic()
        XCTAssertTrue(counts.isEmpty)
    }

    func testMarkAllReadWithinCapSyncsEveryTargetSilently() async throws {
        let store = try MessageStore.inMemory()
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")
        for i in 0..<3 {
            try await store.upsert(makeMessage(id: "msg\(i)", topic: "alpha"), serverURL: ref.serverURL)
        }

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.serverMarkReadSession = markReadMockSession(status: 200)

        vm.markAllRead(for: ref)

        try await waitUntil { MarkReadMockProtocol.paths.count == 1 }
        let synced = Set(
            MarkReadMockProtocol.paths.first!.components(separatedBy: "/")[1]
                .components(separatedBy: ",")
        )
        XCTAssertEqual(synced, ["msg0", "msg1", "msg2"])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(vm.serverSyncNotice)  // full success needs no explanation
    }

    func testMarkAllReadReportsFirstServerRejection() async throws {
        let store = try MessageStore.inMemory()
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")
        for i in 0..<3 {
            try await store.upsert(makeMessage(id: "msg\(i)", topic: "alpha"), serverURL: ref.serverURL)
        }

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.serverMarkReadSession = markReadMockSession(status: 403)  // read-only token

        vm.markAllRead(for: ref)

        try await waitUntil { vm.serverSyncNotice != nil }
        XCTAssertEqual(MarkReadMockProtocol.paths.count, 1)  // stopped at the first rejection
        XCTAssertTrue(vm.serverSyncNotice!.contains("0/3"))

        // Rejection does not roll back the local read state.
        let counts = try await store.unreadCountsByTopic()
        XCTAssertTrue(counts.isEmpty)
    }

    // MARK: - Clear topic on the server

    /// "清空" used to be local-only, so the messages stayed on every other device. The
    /// destructive action now has a server variant; the plain one must stay local.
    func testClearTopicIsLocalOnlyByDefault() async throws {
        let store = try MessageStore.inMemory()
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")
        try await store.upsert(makeMessage(id: "m1", topic: "alpha"), serverURL: ref.serverURL)

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.serverMarkReadSession = markReadMockSession(status: 200)

        vm.clearTopic(ref)

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(MarkReadMockProtocol.paths.isEmpty)
        let live = try await store.messages(serverURL: ref.serverURL, topic: "alpha")
        XCTAssertTrue(live.isEmpty)
    }

    func testClearTopicOnServerDeletesEveryMessage() async throws {
        let store = try MessageStore.inMemory()
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")
        for i in 0..<3 {
            try await store.upsert(
                makeMessage(id: "msg\(i)", topic: "alpha", time: 1_700_000_000 + i),
                serverURL: ref.serverURL
            )
        }

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.serverMarkReadSession = markReadMockSession(status: 200)

        vm.clearTopic(ref, withServer: true)

        // The delete route takes one id per request, so three messages mean three requests.
        try await waitUntil { MarkReadMockProtocol.paths.count == 3 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(vm.serverSyncNotice)
    }

    func testClearTopicOnServerReportsRejection() async throws {
        let store = try MessageStore.inMemory()
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")
        try await store.upsert(makeMessage(id: "msg0", topic: "alpha"), serverURL: ref.serverURL)

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.serverMarkReadSession = markReadMockSession(status: 403)

        vm.clearTopic(ref, withServer: true)

        try await waitUntil { vm.serverSyncNotice != nil }
        XCTAssertTrue(vm.serverSyncNotice!.contains("0/1"))
    }

    // MARK: - Server topic browser

    func testBrowserEntriesClassifyLiveAndSubscribedTopics() {
        let entries = HistoryViewModel.browserEntries(
            serverURL: "https://s.example",
            live: ["releases", "alerts"],
            subscribed: ["alerts", "private-stuff"]
        )
        XCTAssertEqual(entries.map(\.topic), ["alerts", "releases", "private-stuff"])
        XCTAssertEqual(entries.map(\.status), [.subscribed, .available, .goneOnServer])
    }

    func testBrowserEntriesKeepsServerWithoutCachedMessagesEmpty() {
        let entries = HistoryViewModel.browserEntries(
            serverURL: "https://s.example", live: [], subscribed: ["alerts"]
        )
        XCTAssertEqual(entries.map(\.topic), ["alerts"])
        XCTAssertEqual(entries.first?.status, .goneOnServer)
    }

    /// Thread-safe recorder for the browser test seams.
    private final class BrowserCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var fetches = 0
        private var retired: String?

        func nextFetchReturnedFirst() -> Bool {
            lock.lock(); defer { lock.unlock() }
            fetches += 1
            return fetches == 1
        }
        func recordRetire(_ value: String) {
            lock.lock(); retired = value; lock.unlock()
        }
        var retireTarget: String? {
            lock.lock(); defer { lock.unlock() }
            return retired
        }
    }

    private func tempConfigPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hvm-\(UUID().uuidString).yml").path
    }

    private func loadSingleServerConfig() throws -> String {
        let src = tempConfigPath()
        let yaml = """
        servers:
          - url: https://s.example
            topics: []
        """
        try yaml.write(toFile: src, atomically: true, encoding: .utf8)
        try ConfigManager.shared.loadConfig(from: src)
        return src
    }

    /// The purge the browser's trash button triggers: the server DELETE runs, then the
    /// re-queried list must no longer contain the retired topic.
    func testRetireTopicPurgesServerAndDropsRow() async throws {
        let src = try loadSingleServerConfig()
        defer { try? FileManager.default.removeItem(atPath: src) }

        let store = try MessageStore.inMemory()
        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        let calls = BrowserCalls()
        vm.topicsFetcher = { _, _ in
            calls.nextFetchReturnedFirst() ? ["releases", "alerts"] : ["alerts"]
        }
        vm.topicRetrier = { serverURL, topic, _ in
            calls.recordRetire("\(serverURL)|\(topic)")
            return 7
        }

        vm.loadServerTopics()
        try await waitUntil { vm.serverTopics["https://s.example"]?.count == 2 }

        vm.retireTopic(TopicRef(serverURL: "https://s.example", topic: "releases"))
        try await waitUntil { calls.retireTarget == "https://s.example|releases" }
        try await waitUntil {
            (vm.serverTopics["https://s.example"] ?? []).map(\.topic) == ["alerts"]
        }
        XCTAssertNil(vm.serverTopicsError)
    }

    func testRetireTopicReportsServerRejection() async throws {
        let src = try loadSingleServerConfig()
        defer { try? FileManager.default.removeItem(atPath: src) }

        let store = try MessageStore.inMemory()
        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.topicsFetcher = { _, _ in ["releases"] }
        vm.topicRetrier = { _, _, _ in throw TopicActionError.httpStatus(403) }

        vm.loadServerTopics()
        try await waitUntil { vm.serverTopics["https://s.example"]?.count == 1 }

        vm.retireTopic(TopicRef(serverURL: "https://s.example", topic: "releases"))
        try await waitUntil { vm.serverTopicsError?.contains("403") == true }
    }

    // MARK: - Global search (audit 3.4)

    private func makeSearchableMessage(id: String, topic: String, message text: String, time: Int) -> NtfyMessage {
        NtfyMessage(
            id: id, time: time, event: "message", topic: topic,
            message: text, title: nil, priority: 3, tags: nil,
            click: nil, actions: nil, attachment: nil, contentType: nil, sequenceId: nil
        )
    }

    func testGlobalSearchFillsResultsAndOpenLeavesSearchMode() async throws {
        let store = try MessageStore.inMemory()
        try await store.upsert(makeSearchableMessage(id: "x1", topic: "alpha", message: "磁盘已满 disk full", time: 1), serverURL: "https://s.example")
        try await store.upsert(makeSearchableMessage(id: "x2", topic: "beta", message: "disk quiet", time: 2), serverURL: "https://s.example")
        try await store.upsert(makeSearchableMessage(id: "x3", topic: "beta", message: "无关", time: 3), serverURL: "https://s1.example")

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.globalQuery = "disk"
        try await waitUntil { vm.globalResults.count == 2 }
        XCTAssertTrue(vm.isGlobalSearchActive)
        XCTAssertEqual(Set(vm.globalResults.map(\.id)), ["x1", "x2"])
        // Newest first across servers.
        XCTAssertEqual(vm.globalResults.first?.id, "x2")

        let hit = vm.globalResults[0]
        vm.openGlobalResult(hit)
        XCTAssertFalse(vm.isGlobalSearchActive)
        XCTAssertEqual(vm.selectedTopic, hit.topicRef)
    }

    func testGlobalSearchEmptyQueryClearsResults() async throws {
        let store = try MessageStore.inMemory()
        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.runGlobalSearch("disk")  // generation bump without DB work
        vm.globalQuery = ""
        try await waitUntil { vm.globalResults.isEmpty && !vm.isGlobalSearching }
    }

    // MARK: - Attachment download (audit 3.5)

    func testAttachmentDownloadFailureSurfacesRetryState() async throws {
        let store = try MessageStore.inMemory()
        let attachment = NtfyMessage.NtfyAttachment(
            name: "f.txt", url: "https://s.example/file/f.txt", type: nil, size: nil, expires: nil
        )
        try await store.upsert(
            NtfyMessage(
                id: "a1", time: 1, event: "message", topic: "alpha",
                message: "m", title: nil, priority: 3, tags: nil,
                click: nil, actions: nil, attachment: attachment, contentType: nil, sequenceId: nil
            ),
            serverURL: "https://s.example"
        )
        let stored = try await store.messages(serverURL: "https://s.example", topic: "alpha")
        XCTAssertEqual(stored.count, 1)

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("att-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        vm.attachmentDirectoryOverride = dir
        vm.attachmentSession = attachmentMockSession(status: 403, body: Data())

        vm.downloadAndOpen(stored[0])
        try await waitUntil { vm.attachmentStates[attachment.url] == .downloading }
        try await waitUntil {
            guard case .failed = vm.attachmentStates[attachment.url] else { return false }
            return true
        }
    }

    /// Store changes used to mean one sidebar aggregate plus one page reload each; they now
    /// settle into a single pass. A burst for the open topic still lands the messages.
    func testStoreChangeBurstSettlesIntoOneRefresh() async throws {
        let store = try MessageStore.inMemory()
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let vm = HistoryViewModel(store: store, syncService: sync)
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")

        try await store.upsert(makeMessage(id: "a1", topic: "alpha"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "a2", topic: "alpha"), serverURL: "https://s.example")

        vm.selectTopic(ref)
        try await waitUntil { vm.messages.count == 2 }
        let rendersAfterLoad = vm.messages.count

        // A replay chunk hands over one notification per topic; ten of them must still leave
        // the list intact rather than reloading it ten times over.
        for _ in 0..<10 {
            NotificationCenter.default.post(
                name: .historyStoreDidChange, object: nil, userInfo: ["topicRef": ref]
            )
        }
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(vm.messages.count, rendersAfterLoad)
        XCTAssertEqual(vm.unread(for: ref), 2)
    }

    private func waitUntil(timeoutSeconds: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met before timeout")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
