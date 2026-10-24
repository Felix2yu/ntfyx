import XCTest
@testable import NtfyxCore

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

    private func loadSingleServerConfig() throws -> (path: String, configStore: ConfigStore) {
        let src = tempConfigPath()
        let yaml = """
        servers:
          - url: https://s.example
            topics: []
        """
        try yaml.write(toFile: src, atomically: true, encoding: .utf8)
        let configStore = ConfigStore()
        try configStore.load(from: src)
        return (src, configStore)
    }

    /// The sidebar and every other surface name a topic by its 备注; the id stays the key
    /// for unread counts and history lookups.
    func testSidebarShowsTheTopicNoteAndKeepsTheIDAsKey() async throws {
        let src = tempConfigPath()
        defer { try? FileManager.default.removeItem(atPath: src) }
        let yaml = """
        servers:
          - url: https://s.example
            topics:
              - name: nightly-backup
                display_name: 夜间备份
              - name: alerts
        """
        try yaml.write(toFile: src, atomically: true, encoding: .utf8)
        let configStore = ConfigStore()
        try configStore.load(from: src)

        let store = try MessageStore.inMemory()
        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store), configStore: configStore)

        vm.refreshSidebar()
        try await waitUntil { vm.groups.first?.topics.count == 2 }

        XCTAssertEqual(vm.groups.first?.topics.map(\.label), ["夜间备份", "alerts"])
        XCTAssertEqual(vm.groups.first?.topics.map(\.id), [
            "https://s.example|nightly-backup", "https://s.example|alerts"
        ], "身份仍然是服务器上的英文主题名")
        XCTAssertEqual(vm.label(for: TopicRef(serverURL: "https://s.example", topic: "nightly-backup")), "夜间备份")
        // A topic this server has no config for (unsubscribed, orphans) keeps its id.
        XCTAssertEqual(vm.label(for: TopicRef(serverURL: "https://other.example", topic: "nightly-backup")), "nightly-backup")
    }

    /// The purge the browser's trash button triggers: the server DELETE runs, then the
    /// re-queried list must no longer contain the retired topic.
    func testRetireTopicPurgesServerAndDropsRow() async throws {
        let (src, configStore) = try loadSingleServerConfig()
        defer { try? FileManager.default.removeItem(atPath: src) }

        let store = try MessageStore.inMemory()
        let vm = HistoryViewModel(
            store: store,
            syncService: HistorySyncService(store: store, configStore: configStore),
            configStore: configStore
        )
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
        let (src, configStore) = try loadSingleServerConfig()
        defer { try? FileManager.default.removeItem(atPath: src) }

        let store = try MessageStore.inMemory()
        let vm = HistoryViewModel(
            store: store,
            syncService: HistorySyncService(store: store, configStore: configStore),
            configStore: configStore
        )
        vm.topicsFetcher = { _, _ in ["releases"] }
        vm.topicRetrier = { _, _, _ in throw TopicActionError.httpStatus(403) }

        vm.loadServerTopics()
        try await waitUntil { vm.serverTopics["https://s.example"]?.count == 1 }

        vm.retireTopic(TopicRef(serverURL: "https://s.example", topic: "releases"))
        try await waitUntil { vm.serverTopicsError?.contains("403") == true }
    }

    /// Clearing the history of a subscribed-but-uncached topic demotes its row (cleanup
    /// button gone, unsubscribe remains) — the subscription itself stays: the topic may
    /// simply have run its messages down to expiry.
    func testClearLocalHistoryDemotesTheRowAndKeepsTheSubscription() async throws {
        let src = tempConfigPath()
        defer { try? FileManager.default.removeItem(atPath: src) }
        let yaml = """
        servers:
          - url: https://s.example
            topics:
              - name: webmonitor
        """
        try yaml.write(toFile: src, atomically: true, encoding: .utf8)
        let configStore = ConfigStore()
        try configStore.load(from: src)

        let store = try MessageStore.inMemory()
        try await store.upsert(
            makeSearchableMessage(id: "wm1", topic: "webmonitor", message: "down", time: 1),
            serverURL: "https://s.example"
        )
        let vm = HistoryViewModel(
            store: store,
            syncService: HistorySyncService(store: store, configStore: configStore),
            configStore: configStore
        )
        vm.topicsFetcher = { _, _ in [] }  // server cache empty → webmonitor is goneOnServer

        vm.loadServerTopics()
        try await waitUntil {
            (vm.serverTopics["https://s.example"] ?? []).map(\.topic) == ["webmonitor"]
        }

        vm.clearLocalHistory(serverURL: "https://s.example", topic: "webmonitor")
        try await waitUntil {
            vm.serverTopics["https://s.example"]?.first?.hasLocalHistory == false
        }
        XCTAssertEqual(vm.serverTopics["https://s.example"]?.map(\.topic), ["webmonitor"])
        XCTAssertEqual(configStore.config?.servers.first?.topics.map(\.name), ["webmonitor"])
    }

    /// A subscribed-but-uncached topic with no local history (a stale duplicate subscription)
    /// is still listed, but with the flag that reduces its actions to unsubscribe alone.
    func testLoadServerTopicsFlagsGoneTopicsWithoutLocalHistory() async throws {
        let src = tempConfigPath()
        defer { try? FileManager.default.removeItem(atPath: src) }
        let yaml = """
        servers:
          - url: https://s.example
            topics:
              - name: webmonitor
        """
        try yaml.write(toFile: src, atomically: true, encoding: .utf8)
        let configStore = ConfigStore()
        try configStore.load(from: src)

        let store = try MessageStore.inMemory()  // no local rows
        let vm = HistoryViewModel(
            store: store,
            syncService: HistorySyncService(store: store, configStore: configStore),
            configStore: configStore
        )
        vm.topicsFetcher = { _, _ in [] }

        vm.loadServerTopics()
        try await waitUntil {
            vm.serverTopics["https://s.example"]?.first?.hasLocalHistory == false
        }
        XCTAssertEqual(vm.serverTopics["https://s.example"]?.map(\.topic), ["webmonitor"])
    }

    /// Unsubscribing a topic the server no longer caches removes the row outright: with the
    /// subscription gone there is neither server cache nor a cleanup left to show.
    func testUnsubscribeRemovesGoneRowAndKeepsLiveRowAvailable() async throws {
        let src = tempConfigPath()
        defer { try? FileManager.default.removeItem(atPath: src) }
        let yaml = """
        servers:
          - url: https://s.example
            topics:
              - name: stale-topic
              - name: live-topic
        """
        try yaml.write(toFile: src, atomically: true, encoding: .utf8)
        let configStore = ConfigStore()
        try configStore.load(from: src)

        let store = try MessageStore.inMemory()
        let vm = HistoryViewModel(
            store: store,
            syncService: HistorySyncService(store: store, configStore: configStore),
            configStore: configStore
        )
        vm.topicsFetcher = { _, _ in ["live-topic"] }

        vm.loadServerTopics()
        try await waitUntil { vm.serverTopics["https://s.example"]?.count == 2 }

        vm.unsubscribe(serverURL: "https://s.example", topic: "stale-topic")
        try await waitUntil {
            vm.serverTopics["https://s.example"]?.map(\.topic) == ["live-topic"]
        }
        XCTAssertEqual(vm.serverTopics["https://s.example"]?.first?.status, .subscribed)
        XCTAssertEqual(configStore.config?.servers.first?.topics.map(\.name), ["live-topic"])

        vm.unsubscribe(serverURL: "https://s.example", topic: "live-topic")
        try await waitUntil {
            vm.serverTopics["https://s.example"]?.first?.status == .available
                && vm.serverTopics["https://s.example"]?.first?.topic == "live-topic"
        }
        XCTAssertEqual(configStore.config?.servers.first?.topics.map(\.name), [])
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

        // A replay chunk hands over one bus change per topic; ten of them must still leave
        // the list intact rather than reloading it ten times over.
        for _ in 0..<10 {
            HistoryChangeBus.shared.post(topicRef: ref)
        }
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(vm.messages.count, rendersAfterLoad)
        XCTAssertEqual(vm.unread(for: ref), 2)
    }

    /// A bus change naming the selected topic refreshes both the sidebar unread count and the
    /// message list (audit B3 — same semantics the old notification consumer had).
    func testBusChangeRefreshesSidebarAndSelectedTopic() async throws {
        let store = try MessageStore.inMemory()
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let vm = HistoryViewModel(store: store, syncService: sync)
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")

        try await store.upsert(makeMessage(id: "a1", topic: "alpha", time: 1), serverURL: "https://s.example")
        vm.selectTopic(ref)
        try await waitUntil { vm.messages.count == 1 && vm.unread(for: ref) == 1 }

        try await store.markRead(true, serverURL: ref.serverURL, topic: ref.topic, messageID: "a1")
        HistoryChangeBus.shared.post(topicRef: ref)

        try await waitUntil { vm.unread(for: ref) == 0 }
    }

    /// Rapid typing must coalesce into a single load for the final query (250 ms Task debounce,
    /// equivalent to the old Combine `removeDuplicates + debounce` pipeline).
    func testSearchDebounceLoadsLastQueryOnly() async throws {
        let store = try MessageStore.inMemory()
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let vm = HistoryViewModel(store: store, syncService: sync)
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")

        try await store.upsert(makeMessage(id: "a1", topic: "alpha", time: 1), serverURL: "https://s.example")
        try await store.upsert(
            NtfyMessage(
                id: "a2", time: 2, event: "message", topic: "alpha",
                message: "the beta hit", title: nil, priority: 3, tags: nil,
                click: nil, actions: nil, attachment: nil, contentType: nil, sequenceId: nil
            ),
            serverURL: "https://s.example"
        )
        vm.selectTopic(ref)
        try await waitUntil { vm.messages.count == 2 }

        vm.searchText = "nomatch-xyz"
        vm.searchText = "beta"
        try await waitUntil { vm.messages.count == 1 }
        XCTAssertEqual(vm.messages.first?.message.id, "a2")
    }

    // MARK: - Merged per-server view

    /// The 全部主题 row has to show one server's topics as a single timeline, newest first,
    /// without pulling another server's rows in.
    func testSelectServerAllMergesEveryTopicOfThatServer() async throws {
        let store = try MessageStore.inMemory()
        try await store.upsert(makeMessage(id: "a1", topic: "alpha", time: 1), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "b1", topic: "beta", time: 2), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "o1", topic: "alpha", time: 3), serverURL: "https://other.example")

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.selectServerAll("https://s.example")
        try await waitUntil { vm.messages.count == 2 }

        XCTAssertEqual(vm.messages.map(\.id), ["b1", "a1"])
        XCTAssertEqual(vm.messages.map(\.topic), ["beta", "alpha"])
        XCTAssertEqual(vm.selectedServerAll, "https://s.example")
        XCTAssertNil(vm.selectedTopic)
    }

    /// A page boundary in the merged list lands wherever it lands, so "load older" must keep
    /// walking the same (time, rowID) cursor across topics instead of per topic.
    func testServerAllLoadOlderPagesAcrossTopics() async throws {
        let store = try MessageStore.inMemory()
        let events = (0..<101).map {
            makeMessage(id: "m\($0)", topic: $0 % 2 == 0 ? "alpha" : "beta", time: 1_000 + $0)
        }
        _ = try await store.applyBatch(events, serverURL: "https://s.example")

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.selectServerAll("https://s.example")
        try await waitUntil { vm.messages.count == HistoryViewModel.pageSize }
        XCTAssertTrue(vm.hasMoreMessages)

        vm.loadOlder()
        try await waitUntil { vm.messages.count == 101 }
        XCTAssertEqual(Set(vm.messages.map(\.id)), Set(events.map(\.id)))
        XCTAssertFalse(vm.hasMoreMessages)
    }

    func testUnreadForServerSumsOnlyItsOwnTopics() async throws {
        let store = try MessageStore.inMemory()
        try await store.upsert(makeMessage(id: "a1", topic: "alpha"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "a2", topic: "alpha"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "b1", topic: "beta"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "o1", topic: "gamma"), serverURL: "https://other.example")

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        try await waitUntil { vm.totalUnread == 4 }
        XCTAssertEqual(vm.unread(forServer: "https://s.example"), 3)
        XCTAssertEqual(vm.unread(forServer: "https://other.example"), 1)
    }

    /// The merged view's 全部已读 covers every topic of that server; other servers keep their
    /// unread rows both locally and on their own hosts.
    func testMarkServerAllReadClearsThatServerOnly() async throws {
        let store = try MessageStore.inMemory()
        try await store.upsert(makeMessage(id: "a1", topic: "alpha"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "b1", topic: "beta"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "o1", topic: "gamma"), serverURL: "https://other.example")

        let vm = HistoryViewModel(store: store, syncService: HistorySyncService(store: store))
        vm.serverMarkReadSession = markReadMockSession(status: 200)
        try await waitUntil { vm.totalUnread == 3 }

        vm.markServerAllRead(serverURL: "https://s.example")
        try await waitUntil { vm.unread(forServer: "https://s.example") == 0 }

        XCTAssertEqual(vm.unread(forServer: "https://other.example"), 1)
        let syncedTopics = Set(MarkReadMockProtocol.paths.map { $0.components(separatedBy: "/").first ?? "" })
        XCTAssertEqual(syncedTopics, ["alpha", "beta"])
    }

    /// Live traffic lands on whichever topic it belongs to; the merged list has to follow
    /// changes of any of its server's topics, and ignore another server's.
    func testStoreChangeReloadsMergedMessagesForItsOwnServer() async throws {
        let store = try MessageStore.inMemory()
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let vm = HistoryViewModel(store: store, syncService: sync)

        try await store.upsert(makeMessage(id: "a1", topic: "alpha", time: 1), serverURL: "https://s.example")
        vm.selectServerAll("https://s.example")
        try await waitUntil { vm.messages.count == 1 }

        try await store.upsert(makeMessage(id: "b1", topic: "beta", time: 2), serverURL: "https://s.example")
        HistoryChangeBus.shared.post(topicRef: TopicRef(serverURL: "https://s.example", topic: "beta"))
        try await waitUntil { vm.messages.count == 2 }
        XCTAssertEqual(vm.messages.first?.id, "b1")

        try await store.upsert(makeMessage(id: "o1", topic: "alpha", time: 3), serverURL: "https://other.example")
        HistoryChangeBus.shared.post(topicRef: TopicRef(serverURL: "https://other.example", topic: "alpha"))
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(vm.messages.count, 2)
    }

    // MARK: - 滚动即已读

    /// 代替 SwiftUI 的布局回报：`tops[i]` 是第 i 行 frame 的上沿，nil 表示那一行压根没被排出来、
    /// 什么都没报（快滑一划正是如此）。坐标系里 y = 0 就是视口上沿，负值即行头已离开窗口。
    private func reportRows(
        _ vm: HistoryViewModel, tops: [CGFloat?], rowHeight: CGFloat = 60
    ) {
        for (index, row) in vm.messages.enumerated() where index < tops.count {
            guard let top = tops[index] else { continue }
            vm.reportRowFrame(row.id, frame: CGRect(x: 0, y: top, width: 300, height: rowHeight))
        }
    }

    /// 整列等距排布：行距 8，第 i 行上沿 = headOffset + i * (行高 + 8)。
    private func reportStack(_ vm: HistoryViewModel, headOffset: CGFloat, rowHeight: CGFloat = 60) {
        reportRows(
            vm,
            tops: vm.messages.indices.map { headOffset + CGFloat($0) * (rowHeight + 8) },
            rowHeight: rowHeight
        )
    }

    /// 滚过的卡片攒成一批发作：一次落库、一次服务器请求、列表不重建（已读行仍留在原处），
    /// 只有侧栏与角标跟着降下来。
    func testScrollReadBatchesWritesAndServerRequests() async throws {
        let store = try MessageStore.inMemory()
        for id in ["m1", "m2", "m3"] {
            try await store.upsert(makeMessage(id: id, topic: "alpha"), serverURL: "https://s.example")
        }
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let vm = HistoryViewModel(store: store, syncService: sync)
        vm.serverMarkReadSession = markReadMockSession(status: 200)

        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")
        vm.onlyUnread = true
        vm.selectTopic(ref)
        try await waitUntil { vm.messages.count == 3 }

        reportStack(vm, headOffset: -300)
        try await waitUntil { vm.messages.allSatisfy(\.isRead) }

        XCTAssertEqual(vm.messages.count, 3, "已读的行仍留在列表里，滚动位置不能被抽走")
        let counts = try await store.unreadCountsByTopic()
        XCTAssertEqual(counts[ref] ?? 0, 0, "库里也必须是已读")

        // 三条消息 = 一条请求（sequenceIDsPerRequest = 50，所以三条落在同一个 chunk）。
        // 请求在落库之后才发出，所以要等它落地，不能直接读快照。
        try await waitUntil { !MarkReadMockProtocol.paths.filter({ $0.hasPrefix("alpha/") }).isEmpty }
        let mine = MarkReadMockProtocol.paths.filter { $0.hasPrefix("alpha/") }
        XCTAssertEqual(mine.count, 1, "滚动不应该每条发一次请求：\(mine)")
        let issued = mine[0].dropFirst("alpha/".count).dropLast("/read".count)
        XCTAssertTrue(mine[0].hasSuffix("/read"), mine.description)
        XCTAssertEqual(Set(issued.split(separator: ",").map(String.init)), ["m1", "m2", "m3"])

        // 同一屏再停一次：位置没变，布局不会再回报，既不该落库也不该请求。
        reportStack(vm, headOffset: -300)
        try await Task.sleep(nanoseconds: 400_000_000)  // 比 settle 窗口长一点
        XCTAssertEqual(MarkReadMockProtocol.paths.filter { $0.hasPrefix("alpha/") }.count, 1,
                       "重复滚过不能重复请求：\(MarkReadMockProtocol.paths)")
    }

    /// The badge and the sidebar follow a scroll-read even though the list itself is untouched.
    func testScrollReadUpdatesCountsWithoutRebuildingTheList() async throws {
        let store = try MessageStore.inMemory()
        try await store.upsert(makeMessage(id: "m1", topic: "alpha"), serverURL: "https://s.example")
        try await store.upsert(makeMessage(id: "m2", topic: "beta"), serverURL: "https://s.example")
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let (src, configStore) = try configuredStore(topics: ["alpha", "beta"])
        defer { try? FileManager.default.removeItem(atPath: src) }
        let vm = HistoryViewModel(store: store, syncService: sync, configStore: configStore)
        vm.serverMarkReadSession = markReadMockSession(status: 200)

        vm.onlyUnread = true
        vm.selectTopic(TopicRef(serverURL: "https://s.example", topic: "alpha"))
        try await waitUntil { vm.messages.count == 1 }
        vm.refreshSidebar()
        try await waitUntil { vm.totalUnread == 2 }

        reportStack(vm, headOffset: -300)
        try await waitUntil { vm.totalUnread == 1 }

        XCTAssertEqual(vm.messages.count, 1, "本主题的列表内容不变")
        XCTAssertEqual(vm.unread(for: TopicRef(serverURL: "https://s.example", topic: "alpha")), 0)
        XCTAssertEqual(vm.unread(for: TopicRef(serverURL: "https://s.example", topic: "beta")), 1)
    }

    /// 点开主题只是"看到"，不是"滚过"：首屏必须保持未读，否则未读数在点击的一瞬间就清零。
    func testOpeningATopicDoesNotReadTheFirstScreen() async throws {
        let store = try MessageStore.inMemory()
        for id in ["m1", "m2"] {
            try await store.upsert(makeMessage(id: id, topic: "alpha"), serverURL: "https://s.example")
        }
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let vm = HistoryViewModel(store: store, syncService: sync)
        vm.serverMarkReadSession = markReadMockSession(status: 200)
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")

        vm.selectTopic(ref)
        try await waitUntil { vm.messages.count == 2 }

        // 首屏：两张卡片都完整待在窗口里，行头谁也没离开上沿 —— 停下也不算看过。
        reportStack(vm, headOffset: 0)
        try await Task.sleep(nanoseconds: 400_000_000)

        var counts = try await store.unreadCountsByTopic()
        XCTAssertEqual(counts[ref] ?? 0, 2, "没有滚动动作就不能把首屏算成已读")
        XCTAssertTrue(MarkReadMockProtocol.paths.filter { $0.hasPrefix("alpha/") }.isEmpty,
                      MarkReadMockProtocol.paths.description)

        // 把它们滚出窗口上沿之后，同一批卡片才被判为已读。
        reportStack(vm, headOffset: -300)
        try await waitUntil { vm.messages.allSatisfy(\.isRead) }
        counts = try await store.unreadCountsByTopic()
        XCTAssertEqual(counts[ref] ?? 0, 0)
    }

    /// 一划带过十几条时被标已读的必须是一段连续前缀，而不是"刚好被量到的那几张"：
    /// 这里只有中间一行报了自己的位置——快滑时 LazyVStack 压根不会排出被跳过的那些行——
    /// 它上面没报的两行也必须跟着已读，它下面还在窗口里的两行必须保持未读。
    func testScrollReadMarksAContiguousPrefix() async throws {
        let store = try MessageStore.inMemory()
        for (offset, id) in ["m1", "m2", "m3", "m4", "m5"].enumerated() {
            try await store.upsert(
                makeMessage(id: id, topic: "alpha", time: 100 - offset), serverURL: "https://s.example"
            )
        }
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let vm = HistoryViewModel(store: store, syncService: sync)
        vm.serverMarkReadSession = markReadMockSession(status: 200)
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")

        vm.selectTopic(ref)
        try await waitUntil { vm.messages.count == 5 }

        // 行高 60 → 水位 = 上沿以上 15。只有第 3 行过了线，第 1、2 行连位置都没报。
        reportRows(vm, tops: [nil, nil, -100, 20, 90])
        try await waitUntil { vm.messages[2].isRead }

        XCTAssertEqual(vm.messages.map(\.isRead), [true, true, true, false, false],
                       "已读必须是一段连续前缀，不能跳号")
        let counts = try await store.unreadCountsByTopic()
        XCTAssertEqual(counts[ref] ?? 0, 2, "库里也必须是同一段前缀已读")
    }

    /// 判据是行头**离开**窗口上沿四分之一行高，不是露进来越多越算看过：一条 200 高的长消息
    /// 只出去 40（20%）时用户看到的还是开头几行，不能算读过。
    func testReadNeedsAQuarterOfTheRowAboveTheWindow() async throws {
        let store = try MessageStore.inMemory()
        try await store.upsert(makeMessage(id: "long", topic: "alpha"), serverURL: "https://s.example")
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let vm = HistoryViewModel(store: store, syncService: sync)
        vm.serverMarkReadSession = markReadMockSession(status: 200)

        vm.selectTopic(TopicRef(serverURL: "https://s.example", topic: "alpha"))
        try await waitUntil { vm.messages.count == 1 }

        reportRows(vm, tops: [-40], rowHeight: 200)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(vm.messages[0].isRead, false, "行头只出去 20% 还不能算读过")

        reportRows(vm, tops: [-50], rowHeight: 200)
        try await waitUntil { vm.messages[0].isRead }
    }

    /// 开着窗口时到达的新消息不属于"滚过的历史"：即便它已经躺在上沿之外、被算进水位，
    /// 用户也可能根本没在看列表，所以既不能自动已读，更不能顺手撤掉横幅。
    func testLiveArrivalSurvivesTheScrollItLandsOn() async throws {
        let store = try MessageStore.inMemory()
        try await store.upsert(makeMessage(id: "old", topic: "alpha", time: 1), serverURL: "https://s.example")
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let vm = HistoryViewModel(store: store, syncService: sync)
        vm.serverMarkReadSession = markReadMockSession(status: 200)
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")

        vm.selectTopic(ref)
        try await waitUntil { vm.messages.count == 1 }

        // 打开时就在那条历史：滚出上沿即已读。
        reportStack(vm, headOffset: -300)
        try await waitUntil { vm.messages[0].isRead }

        // 实时到达：列表因 store 变化重查，新条排在最前，但仍是未读。
        try await store.upsert(makeMessage(id: "live", topic: "alpha", time: 2), serverURL: "https://s.example")
        HistoryChangeBus.shared.post(topicRef: ref)
        try await waitUntil { vm.messages.map(\.message.id) == ["live", "old"] }

        // 整列滚过水位，live 那条也在段内——水位不碰它。
        reportStack(vm, headOffset: -300)
        try await Task.sleep(nanoseconds: 400_000_000)

        let counts = try await store.unreadCountsByTopic()
        XCTAssertEqual(counts[ref] ?? 0, 1, "刚到的一条不能被自动标成已读")
        XCTAssertEqual(vm.messages.first { $0.message.id == "live" }?.isRead, false)
    }

    /// 切主题把那一刻的存量算作可自动已读的历史：之前 live 到达的那条，滚动它时才被判为已读。
    func testSelectingAgainMakesEarlierLiveMessagesBacklog() async throws {
        let store = try MessageStore.inMemory()
        try await store.upsert(makeMessage(id: "live", topic: "alpha", time: 2), serverURL: "https://s.example")
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let vm = HistoryViewModel(store: store, syncService: sync)
        vm.serverMarkReadSession = markReadMockSession(status: 200)

        vm.selectTopic(TopicRef(serverURL: "https://s.example", topic: "alpha"))
        try await waitUntil { vm.messages.count == 1 }
        try await waitUntil { vm.totalUnread == 1 }

        // 选中主题只是把这条摆进窗口，行头没离开上沿 —— 停下也不算滚过。
        reportStack(vm, headOffset: 0)
        try await Task.sleep(nanoseconds: 400_000_000)
        var counts = try await store.unreadCountsByTopic()
        XCTAssertEqual(counts.values.reduce(0, +), 1, "点开主题的一瞬间不该清零")

        reportStack(vm, headOffset: -300)
        try await waitUntil { vm.messages[0].isRead }
        counts = try await store.unreadCountsByTopic()
        XCTAssertEqual(counts.values.reduce(0, +), 0)
    }

    private func configuredStore(topics: [String]) throws -> (path: String, configStore: ConfigStore) {
        let src = tempConfigPath()
        let yaml = """
        servers:
          - url: https://s.example
            topics:
        """ + topics.map { "\n              - name: \($0)" }.joined()
        try yaml.write(toFile: src, atomically: true, encoding: .utf8)
        let configStore = ConfigStore()
        try configStore.load(from: src)
        return (src, configStore)
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
