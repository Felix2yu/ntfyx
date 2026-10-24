import XCTest
@testable import NtfyxCore

// MARK: - Mock URLProtocol for mark-read failures

/// Answers every /read request with a fixed status, recording the paths it saw —
/// the failure side of the outbox tests.
private final class FailingMarkReadProtocol: URLProtocol {
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
        FailingMarkReadProtocol.lock.lock()
        FailingMarkReadProtocol._paths.append(request.url?.path ?? "")
        let status = FailingMarkReadProtocol._status
        FailingMarkReadProtocol.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func failingMarkReadSession(status: Int) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FailingMarkReadProtocol.self]
    FailingMarkReadProtocol.reset(status: status)
    return URLSession(configuration: config)
}

/// 已读上抛的 outbox：标记已读是本地先行、`/read` 尽力而为，所以服务器没接受的
/// 那部分必须落进 `pending_read` 等待重连重放，而不是无声丢失——那正是两端
/// 已读状态不一致的主要来源。这些测试钉住入队、取出、删除与各失败路径。
@MainActor
final class PendingReadOutboxTests: XCTestCase {

    private func makeMessage(id: String, topic: String, time: Int = 1_700_000_000) -> NtfyMessage {
        NtfyMessage(
            id: id, time: time, event: "message", topic: topic,
            message: "body", title: nil, priority: 3, tags: nil,
            click: nil, actions: nil, attachment: nil, contentType: nil, sequenceId: nil
        )
    }

    private func waitUntil(timeoutSeconds: TimeInterval = 5, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !(await condition()) {
            if Date() > deadline {
                XCTFail("condition not met before timeout")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Store round trip

    func testPendingReadsGroupByTopicAndDeduplicate() async throws {
        let store = try MessageStore.inMemory()
        try await store.enqueuePendingReads(serverURL: "https://s.example", topic: "alpha", ids: ["a1", "a2"])
        try await store.enqueuePendingReads(serverURL: "https://s.example", topic: "beta", ids: ["b1"])
        // 重放前的重复入队不能翻倍。
        try await store.enqueuePendingReads(serverURL: "https://s.example", topic: "alpha", ids: ["a1"])

        let pending = try await store.pendingReadIDs(serverURL: "https://s.example")
        XCTAssertEqual(Set(pending["alpha"] ?? []), ["a1", "a2"])
        XCTAssertEqual(pending["beta"], ["b1"])
    }

    func testRemovePendingReadsDropsOnlyAcceptedIds() async throws {
        let store = try MessageStore.inMemory()
        try await store.enqueuePendingReads(serverURL: "https://s.example", topic: "alpha", ids: ["a1", "a2", "a3"])
        try await store.removePendingReads(serverURL: "https://s.example", topic: "alpha", ids: ["a1", "a3"])

        let pending = try await store.pendingReadIDs(serverURL: "https://s.example")
        XCTAssertEqual(pending["alpha"], ["a2"])
    }

    func testDeleteTopicClearsItsPendingReads() async throws {
        let store = try MessageStore.inMemory()
        try await store.enqueuePendingReads(serverURL: "https://s.example", topic: "alpha", ids: ["a1"])
        try await store.enqueuePendingReads(serverURL: "https://s.example", topic: "beta", ids: ["b1"])
        try await store.deleteTopic(serverURL: "https://s.example", topic: "alpha")

        let pending = try await store.pendingReadIDs(serverURL: "https://s.example")
        XCTAssertNil(pending["alpha"])
        XCTAssertEqual(pending["beta"], ["b1"])
    }

    // MARK: - Failure paths queue instead of dropping

    func testScrollReadFailureQueuesUnsentIds() async throws {
        let store = try MessageStore.inMemory()
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")
        for id in ["m1", "m2", "m3"] {
            try await store.upsert(makeMessage(id: id, topic: "alpha"), serverURL: ref.serverURL)
        }
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let vm = HistoryViewModel(store: store, syncService: sync)
        vm.serverMarkReadSession = failingMarkReadSession(status: 403)

        vm.selectTopic(ref)
        try await waitUntil { vm.messages.count == 3 }
        reportStack(vm, headOffset: -300)
        try await waitUntil { vm.messages.allSatisfy(\.isRead) }

        // 服务器拒绝后，已读标记必须排队而不是丢掉。
        try await waitUntil {
            (try? await store.pendingReadIDs(serverURL: ref.serverURL))?["alpha"]?.count == 3
        }
        let counts = try await store.unreadCountsByTopic()
        XCTAssertTrue(counts.isEmpty, "本地已读先行，不受服务器失败影响")
    }

    func testMarkAllReadFailureQueuesUnsentIdsAndSaysSo() async throws {
        let store = try MessageStore.inMemory()
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")
        for i in 0..<3 {
            try await store.upsert(makeMessage(id: "msg\(i)", topic: "alpha"), serverURL: ref.serverURL)
        }
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let vm = HistoryViewModel(store: store, syncService: sync)
        vm.serverMarkReadSession = failingMarkReadSession(status: 500)

        vm.markAllRead(for: ref)
        try await waitUntil { vm.serverSyncNotice != nil }
        XCTAssertTrue(vm.serverSyncNotice!.contains("已排队"), vm.serverSyncNotice!)

        try await waitUntil {
            (try? await store.pendingReadIDs(serverURL: ref.serverURL))?["alpha"]?.count == 3
        }
    }

    /// 开了认证的服务器对无 token 的客户端恒回 401/403：提示必须点出 token 问题
    /// （而不是承诺一次不可能成功的重试），标记仍然入队——补上有效 token 后即可自愈。
    func testMarkAllReadRejectionNamesTheTokenProblemAndStillQueues() async throws {
        let store = try MessageStore.inMemory()
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")
        for i in 0..<3 {
            try await store.upsert(makeMessage(id: "msg\(i)", topic: "alpha"), serverURL: ref.serverURL)
        }
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let vm = HistoryViewModel(store: store, syncService: sync)
        vm.serverMarkReadSession = failingMarkReadSession(status: 403)

        vm.markAllRead(for: ref)
        try await waitUntil { vm.serverSyncNotice != nil }
        XCTAssertTrue(vm.serverSyncNotice!.contains("无写权限"), vm.serverSyncNotice!)
        XCTAssertTrue(vm.serverSyncNotice!.contains("HTTP 403"), vm.serverSyncNotice!)

        try await waitUntil {
            (try? await store.pendingReadIDs(serverURL: ref.serverURL))?["alpha"]?.count == 3
        }
    }

    /// 队列只能靠重放清空：一直被拒绝的服务器会让它无限增长，所以按年龄设界。
    func testRetentionPrunesAgedPendingReads() async throws {
        let store = try MessageStore.inMemory()
        try await store.enqueuePendingReads(serverURL: "https://s.example", topic: "alpha", ids: ["a1"])

        // 30 天内不动。
        _ = try await store.enforceRetention(now: Date(timeIntervalSinceNow: 29 * 86_400))
        var pending = try await store.pendingReadIDs(serverURL: "https://s.example")
        XCTAssertEqual(pending["alpha"], ["a1"])

        // 超过保留期即清掉。
        _ = try await store.enforceRetention(now: Date(timeIntervalSinceNow: 31 * 86_400))
        pending = try await store.pendingReadIDs(serverURL: "https://s.example")
        XCTAssertNil(pending["alpha"])
    }

    func testToggleReadFailureQueuesTheTarget() async throws {
        let store = try MessageStore.inMemory()
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")
        try await store.upsert(makeMessage(id: "m1", topic: "alpha"), serverURL: ref.serverURL)
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let vm = HistoryViewModel(store: store, syncService: sync)
        vm.serverMarkReadSession = failingMarkReadSession(status: 403)

        vm.selectTopic(ref)
        try await waitUntil { vm.messages.count == 1 }
        guard let stored = vm.messages.first else { return XCTFail("no row") }
        vm.toggleRead(stored)

        try await waitUntil {
            (try? await store.pendingReadIDs(serverURL: ref.serverURL))?["alpha"] == ["m1"]
        }
        let counts = try await store.unreadCountsByTopic()
        XCTAssertTrue(counts.isEmpty, "本地已读先行")
    }

    // MARK: - Live reload keeps the paged depth open

    /// 用户用「加载更多」翻开的旧页，不能被一条新消息触发的 live reload 塌缩回第一页——
    /// 那会抽走正在读的行，滚动已读也就无从判起。
    func testLiveReloadPreservesPagedDepth() async throws {
        let store = try MessageStore.inMemory()
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")
        let total = HistoryViewModel.pageSize + 50
        for i in 0..<total {
            try await store.upsert(makeMessage(id: "m\(i)", topic: "alpha", time: 1_000 + i), serverURL: ref.serverURL)
        }
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let vm = HistoryViewModel(store: store, syncService: sync)
        vm.serverMarkReadSession = failingMarkReadSession(status: 200)

        vm.selectTopic(ref)
        try await waitUntil { vm.messages.count == HistoryViewModel.pageSize }
        vm.loadOlder()
        try await waitUntil { vm.messages.count == total }

        try await store.upsert(makeMessage(id: "fresh", topic: "alpha", time: 9_999), serverURL: ref.serverURL)
        HistoryChangeBus.shared.post(topicRef: ref)
        try await waitUntil { vm.messages.first?.id == "fresh" }

        XCTAssertGreaterThanOrEqual(vm.messages.count, total, "live reload 不能把已翻开的旧页塌缩掉")
        XCTAssertEqual(vm.messages.last?.id, "m0", "最旧的行还在，没有被塌缩回第一页")
        XCTAssertFalse(vm.hasMoreMessages, "整条时间线都在了，就没有更旧的页可加载")
    }

    // MARK: - Scroll-read frontier follows the live end

    private func reportRows(_ vm: HistoryViewModel, tops: [CGFloat?], rowHeight: CGFloat = 60) {
        for (index, row) in vm.messages.enumerated() where index < tops.count {
            guard let top = tops[index] else { continue }
            vm.reportRowFrame(row.id, frame: CGRect(x: 0, y: top, width: 300, height: rowHeight))
        }
    }

    private func reportStack(_ vm: HistoryViewModel, headOffset: CGFloat, rowHeight: CGFloat = 60) {
        reportRows(
            vm,
            tops: vm.messages.indices.map { headOffset + CGFloat($0) * (rowHeight + 8) },
            rowHeight: rowHeight
        )
    }

    /// 窗口开着时新到的消息，过去永远进不了滚动已读的范围；用户停在列表顶部看着
    /// 实时末端时，新到的行就在眼前，滚过它就应该能标已读。
    func testAtTopLiveArrivalBecomesScrollReadable() async throws {
        let store = try MessageStore.inMemory()
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")
        try await store.upsert(makeMessage(id: "m1", topic: "alpha", time: 100), serverURL: ref.serverURL)
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let vm = HistoryViewModel(store: store, syncService: sync)
        vm.serverMarkReadSession = failingMarkReadSession(status: 200)

        vm.selectTopic(ref)
        try await waitUntil { vm.messages.count == 1 }
        // 用户停在顶部：首行的行头还在视口内。
        reportStack(vm, headOffset: 0)
        try await Task.sleep(nanoseconds: 300_000_000)

        try await store.upsert(makeMessage(id: "m2", topic: "alpha", time: 200), serverURL: ref.serverURL)
        HistoryChangeBus.shared.post(topicRef: ref)
        try await waitUntil { vm.messages.count == 2 && vm.messages.first?.id == "m2" }

        // 仍在顶部（两行都完整可见），停一拍让顶部判定推进 frontier。
        reportStack(vm, headOffset: 0)
        try await Task.sleep(nanoseconds: 300_000_000)

        // 滚过这两行：live 到达的 m2 也要能被标已读。
        reportStack(vm, headOffset: -300)
        try await waitUntil { vm.messages.allSatisfy(\.isRead) }
    }

    /// 用户深在历史里时，顶部新到的消息没有上过屏幕，滚动已读绝不能顺手把它标掉。
    func testDeepScrollLiveArrivalStaysUnread() async throws {
        let store = try MessageStore.inMemory()
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")
        for i in 1...5 {
            try await store.upsert(makeMessage(id: "m\(i)", topic: "alpha", time: 100 * i), serverURL: ref.serverURL)
        }
        let sync = HistorySyncService(store: store)
        sync.poll = { _, _, _, _, _ in NtfyPollClient.PollResult() }
        let vm = HistoryViewModel(store: store, syncService: sync)
        vm.serverMarkReadSession = failingMarkReadSession(status: 200)

        vm.selectTopic(ref)
        try await waitUntil { vm.messages.count == 5 }
        // 滚到深处：五行的行头全部离开视口上沿（都被看过）。
        reportStack(vm, headOffset: -400)
        try await waitUntil { vm.messages.allSatisfy(\.isRead) }

        try await store.upsert(makeMessage(id: "fresh", topic: "alpha", time: 9_999), serverURL: ref.serverURL)
        HistoryChangeBus.shared.post(topicRef: ref)
        try await waitUntil { vm.messages.first?.id == "fresh" }

        // 再往下滚一点：可见行都滚过上沿，但没上过屏幕的 fresh 必须保持未读。
        reportStack(vm, headOffset: -470)
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(vm.messages.first?.isRead, false, "没看过的消息不能被滚动已读吞掉")
        let counts = try await store.unreadCountsByTopic()
        XCTAssertEqual(counts[ref] ?? 0, 1)
    }
}

/// 截断的回放不能推进同步游标：服务器按体积上限截断时丢掉的是更旧的行，
/// 游标跳到最新事件会让那些行永远不再被增量同步看到。
@MainActor
final class TruncatedSyncTests: XCTestCase {

    private func makeEvent(id: String, time: Int) -> NtfyMessage {
        NtfyMessage(
            id: id, time: time, event: "message", topic: "alpha",
            message: nil, title: nil, priority: nil, tags: nil,
            click: nil, actions: nil, attachment: nil, contentType: nil, sequenceId: nil
        )
    }

    func testTruncatedSyncKeepsTheCursor() async throws {
        let store = try MessageStore.inMemory()
        let sync = HistorySyncService(store: store)
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")

        var result = NtfyPollClient.PollResult()
        result.messageCount = 1
        result.newestEvent = makeEvent(id: "evt9", time: 900)
        result.truncated = true
        let canned = result
        sync.poll = { _, _, _, _, _ in canned }

        await sync.syncIncremental(ref)

        let info = try await store.latestSyncedInfo(serverURL: ref.serverURL, topic: ref.topic)
        XCTAssertNil(info, "截断的回放不能把游标推进到最新事件")
    }

    func testCompleteSyncAdvancesTheCursor() async throws {
        let store = try MessageStore.inMemory()
        let sync = HistorySyncService(store: store)
        let ref = TopicRef(serverURL: "https://s.example", topic: "alpha")

        var result = NtfyPollClient.PollResult()
        result.messageCount = 1
        result.newestEvent = makeEvent(id: "evt9", time: 900)
        let canned = result
        sync.poll = { _, _, _, _, _ in canned }

        await sync.syncIncremental(ref)

        let info = try await store.latestSyncedInfo(serverURL: ref.serverURL, topic: ref.topic)
        XCTAssertEqual(info?.id, "evt9")
    }
}
