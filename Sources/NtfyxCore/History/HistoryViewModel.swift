import Foundation
import AppKit
import Observation

/// Drives the notification-history window.
///
/// Store changes arrive through `HistoryChangeBus` (audit B3 — the old `NotificationCenter`
/// userInfo channel) and are coalesced with a Task-based settle instead of a Foundation
/// `Timer`; search input debounce works the same way instead of a Combine pipeline.
@MainActor
@Observable
public final class HistoryViewModel {

    // MARK: - Data

    public struct ServerGroup: Identifiable, Equatable {
        public var id: String { url }
        public let url: String
        public var topics: [TopicEntry]
    }

    public struct TopicEntry: Identifiable, Hashable {
        public var id: String { "\(ref.serverURL)|\(ref.topic)" }
        let ref: TopicRef
        public let iconSymbol: String?
        /// The configured 备注, or the topic id when none is set.
        public let label: String
        public var unread: Int
    }

    var groups: [ServerGroup] = []

    /// Sidebar selection: one topic, or every topic of one server merged into one timeline.
    enum Selection: Hashable {
        case topic(TopicRef)
        case serverAll(String)
    }

    var selection: Selection? {
        didSet {
            guard oldValue != selection else { return }
            handleSelectionChange()
        }
    }

    var selectedTopic: TopicRef? {
        if case .topic(let ref) = selection { return ref }
        return nil
    }

    /// Server whose topics are merged into the list, nil unless the aggregate is selected.
    var selectedServerAll: String? {
        if case .serverAll(let serverURL) = selection { return serverURL }
        return nil
    }

    var messages: [StoredMessage] = []

    /// Newest message time among the rows a user-driven load put on screen. A message newer
    /// than this arrived *while the window was up*: it keeps its banner and its unread state
    /// until the user acknowledges it, because an automatic read must never swallow a live
    /// message the user is still waiting for.
    private var scrollReadFrontier = 0
    var hasMoreMessages = false
    var isLoadingOlder = false

    var onlyUnread = false

    var searchText = "" {
        didSet {
            guard oldValue != searchText else { return }
            scheduleTopicSearch()
        }
    }

    var globalQuery = "" {
        didSet {
            guard oldValue != globalQuery else { return }
            scheduleGlobalSearch()
        }
    }

    var globalResults: [StoredMessage] = []
    var isGlobalSearching = false

    /// Per-topic attachment download state, keyed by attachment URL.
    var attachmentStates: [String: AttachmentState] = [:]

    enum AttachmentState: Equatable {
        case downloading
        case failed(reason: String)
    }

    var confirmClearTopic: TopicRef?
    var confirmRetireTopic: TopicRef?

    /// Shown when the server could not accept all local read/delete marks.
    var serverSyncNotice: String?

    // MARK: - Server topic browser

    struct ServerTopicEntry: Identifiable, Hashable {
        var id: String { "\(serverURL)|\(topic)" }
        let serverURL: String
        let topic: String
        var status: Status

        enum Status: Equatable {
            case available
            case subscribed
            case goneOnServer
        }
    }

    var serverTopics: [String: [ServerTopicEntry]] = [:]
    var serverTopicsError: String?
    var isLoadingServerTopics = false

    // MARK: - Dependencies

    private let store: MessageStore
    let syncService: HistorySyncService
    private let configStore: ConfigStore
    private let changeBus = HistoryChangeBus.shared

    var unreadCounts: [TopicRef: Int] = [:]

    static let pageSize = 100
    static let globalSearchCap = 200
    static let serverMarkReadCap = 500
    static let serverClearCap = 100
    private static let storeChangeSettleTime: TimeInterval = 0.25
    private static let searchDebounce: TimeInterval = 0.25

    private var loadGeneration = 0
    private var globalSearchGeneration = 0

    // MARK: - Test seams

    var topicsFetcher: @Sendable (String, String?) async throws -> [String] = {
        try await MessageActionService.fetchServerTopics(serverURL: $0, authToken: $1)
    }
    var topicRetrier: @Sendable (String, String, String?) async throws -> Int = {
        try await MessageActionService.retireTopic(serverURL: $0, topic: $1, authToken: $2)
    }
    var serverMarkReadSession: URLSession = .shared

    // MARK: - Debounce / coalesce tasks (audit B3: Tasks instead of Timer + Combine)

    private var topicSearchTask: Task<Void, Never>?
    private var globalSearchTask: Task<Void, Never>?
    private var storeChangeSettleTask: Task<Void, Never>?
    private var pendingStoreChangeTopics: Set<TopicRef> = []
    /// Topics whose unread count moved while their rows stayed put (scroll-to-read).
    private var pendingCountsOnlyTopics: Set<TopicRef> = []
    private var pendingStoreChangeIsGlobal = false

    // MARK: - Init

    public init(store: MessageStore, syncService: HistorySyncService, configStore: ConfigStore = .shared) {
        self.store = store
        self.syncService = syncService
        self.configStore = configStore
        busCancellation.task = Task { [weak self, changeBus] in
            for await change in changeBus.changes() {
                self?.noteStoreChange(topicRef: change.topicRef, countsOnly: change.countsOnly)
            }
        }
        refreshSidebar()
    }

    /// The multicast stream is held until this view model goes away; cancellation unregisters
    /// the continuation inside `HistoryChangeBus`, so a closed history window leaves no
    /// parked consumer behind. The Sendable box exists only so `deinit` can cancel the task.
    private let busCancellation = CancellableBox()

    deinit {
        busCancellation.task?.cancel()
    }

    private final class CancellableBox: @unchecked Sendable {
        var task: Task<Void, Never>?
    }

    // MARK: - Sidebar

    func refreshSidebar() {
        Task { [weak self] in
            guard let self else { return }
            let counts = (try? await self.store.unreadCountsByTopic()) ?? [:]
            self.unreadCounts = counts

            var newGroups: [ServerGroup] = []
            if let config = self.configStore.config {
                for server in config.servers {
                    let entries = server.topics.map { topic in
                        TopicEntry(
                            ref: TopicRef(serverURL: server.url, topic: topic.name),
                            iconSymbol: topic.iconSymbol,
                            label: topic.label,
                            unread: counts[TopicRef(serverURL: server.url, topic: topic.name)] ?? 0
                        )
                    }
                    newGroups.append(ServerGroup(url: server.url, topics: entries))
                }
            }
            self.groups = newGroups
        }
    }

    var totalUnread: Int {
        unreadCounts.values.reduce(0, +)
    }

    /// The name a topic is shown under: its configured 备注, else the id itself.
    /// Unsubscribed topics (server browser, orphaned history rows) have no config, so they
    /// keep showing the id.
    func label(for ref: TopicRef) -> String {
        configStore.config?.topicConfig(serverURL: ref.serverURL, topic: ref.topic)?.label ?? ref.topic
    }

    func unread(for ref: TopicRef) -> Int {
        unreadCounts[ref] ?? 0
    }

    /// Unread messages over every topic the server has history rows for.
    func unread(forServer serverURL: String) -> Int {
        unreadCounts.reduce(0) { total, entry in
            entry.key.serverURL == serverURL ? total + entry.value : total
        }
    }

    // MARK: - Selection & messages

    func selectTopic(_ ref: TopicRef?) {
        selection = ref.map(Selection.topic)
    }

    /// Selects the merged timeline of every topic stored for this server.
    func selectServerAll(_ serverURL: String) {
        selection = .serverAll(serverURL)
    }

    /// What the message list pages through; a nil topic means every topic of the server.
    private var messageScope: (serverURL: String, topic: String?)? {
        switch selection {
        case .topic(let ref): return (ref.serverURL, ref.topic)
        case .serverAll(let serverURL): return (serverURL, nil)
        case nil: return nil
        }
    }

    /// Selects the first subscribed topic matching `name` on any configured server.
    /// Used by routing (notification clicks, reopen) that only carries a topic name.
    public func selectTopic(named name: String) {
        guard let config = configStore.config else { return }
        for server in config.servers {
            if let topic = server.topics.first(where: { $0.name == name }) {
                refreshSidebar()
                selectTopic(TopicRef(serverURL: server.url, topic: topic.name))
                return
            }
        }
    }

    private func handleSelectionChange() {
        serverSyncNotice = nil
        // A gesture that ended on the previous topic must not keep reading the new one.
        scrollSettleTask?.cancel()
        reloadMessages()
        // Only a single topic syncs on selection: the merged view would fan the pull out
        // over every topic of the server, and it stays current through store changes anyway.
        if case .topic(let ref) = selection {
            Task { [weak self] in
                guard let self else { return }
                await self.syncService.syncIncremental(ref)
                self.refreshSidebar()
                self.reloadMessages()
            }
        }
    }

    /// - Parameter liveUpdate: true when the reload follows a store change (a message arrived or
    ///   was edited) instead of a user action. Only user-driven loads move `scrollReadFrontier`,
    ///   so the very list a live message lands on can never auto-read it.
    func reloadMessages(liveUpdate: Bool = false) {
        guard let scope = messageScope else {
            messages = []
            hasMoreMessages = false
            if !liveUpdate { scrollReadFrontier = 0 }
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        let onlyUnread = self.onlyUnread
        let searchText = self.searchText
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.store.messages(
                    serverURL: scope.serverURL,
                    topic: scope.topic,
                    limit: Self.pageSize,
                    before: nil,
                    onlyUnread: onlyUnread,
                    searchText: searchText.isEmpty ? nil : searchText
                )
                guard generation == self.loadGeneration else { return }  // stale response
                self.messages = page
                // A frame belongs to the layout it was measured in. A different page — or the
                // same message ids under a different topic — must not inherit the old positions.
                rowFrames.removeAll(keepingCapacity: true)
                self.hasMoreMessages = page.count >= Self.pageSize
                if !liveUpdate {
                    self.scrollReadFrontier = page.map(\.time).max() ?? 0
                }
            } catch {
                Log.error("History: failed to load messages: \(error)")
            }
        }
    }

    // MARK: - Search debounce

    private func scheduleTopicSearch() {
        topicSearchTask?.cancel()
        topicSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.searchDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.reloadMessages()
        }
    }

    private func scheduleGlobalSearch() {
        globalSearchTask?.cancel()
        let query = globalQuery
        globalSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.searchDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.runGlobalSearch(query)
        }
    }

    // MARK: - Global search

    var isGlobalSearchActive: Bool { !globalQuery.isEmpty }

    func runGlobalSearch(_ query: String) {
        globalSearchGeneration += 1
        let generation = globalSearchGeneration
        guard !query.isEmpty else {
            globalResults = []
            isGlobalSearching = false
            return
        }
        isGlobalSearching = true
        Task { [weak self] in
            guard let self else { return }
            let results = (try? await self.store.searchAll(query: query, limit: Self.globalSearchCap)) ?? []
            guard generation == self.globalSearchGeneration else { return }  // stale response
            self.globalResults = results
            self.isGlobalSearching = false
        }
    }

    /// Jumps to the hit's topic and leaves search mode.
    func openGlobalResult(_ stored: StoredMessage) {
        globalQuery = ""
        selectTopic(stored.topicRef)
    }

    /// Loads older messages (cursor pagination).
    func loadOlder() {
        guard let scope = messageScope,
              !isLoadingOlder,
              hasMoreMessages,
              let oldest = messages.last else { return }
        let olderCursor = oldest.cursor

        isLoadingOlder = true
        let onlyUnread = self.onlyUnread
        let searchText = self.searchText
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingOlder = false }
            do {
                let older = try await self.store.messages(
                    serverURL: scope.serverURL,
                    topic: scope.topic,
                    limit: Self.pageSize,
                    before: olderCursor,
                    onlyUnread: onlyUnread,
                    searchText: searchText.isEmpty ? nil : searchText
                )
                self.messages.append(contentsOf: older)
                self.hasMoreMessages = older.count >= Self.pageSize
            } catch {
                Log.error("History: failed to load older messages: \(error)")
            }
        }
    }

    /// Re-fetch after a full sync.
    func loadFullHistory() {
        guard let ref = selectedTopic else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.syncService.syncFull(ref)
            self.refreshSidebar()
            self.reloadMessages()
        }
    }

    /// Manual retry entry for failed/rate-limited syncs (audit 2.5).
    func retrySync() {
        guard let ref = selectedTopic else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.syncService.syncIncremental(ref)
            self.refreshSidebar()
            self.reloadMessages()
        }
    }

    // MARK: - Actions

    func toggleRead(_ stored: StoredMessage) {
        let ref = stored.topicRef
        let target = !stored.isRead
        let sequenceID = stored.message.sequenceId
        let messageID = stored.message.id
        Task { [weak self] in
            guard let self else { return }
            try? await self.store.markRead(target, serverURL: ref.serverURL, topic: ref.topic, messageID: messageID)
            self.postStoreChange(for: ref)
            guard target else { return }
            // Reading a message here takes its banner off, same as the web and phone apps do.
            NotificationManager.shared.revoke(messageIDs: [messageID])
            // There is no "mark unread" endpoint; marking read asks the server to
            // broadcast message_clear so other devices converge too.
            await MessageActionService.markReadOnServer(
                serverURL: ref.serverURL,
                topic: ref.topic,
                sequenceID: sequenceID,
                messageID: messageID,
                authToken: configStore.authToken(forServer: ref.serverURL)
            )
        }
    }

    // MARK: - Scroll-to-read (滚动即已读)

    /// Last measured position per row — see `reportRowFrame`. Nothing is judged here.
    @ObservationIgnored private var rowFrames: [String: CGRect] = [:]
    @ObservationIgnored private var scrollSettleTask: Task<Void, Never>?
    /// Rows already handed to a write that has not landed yet; a second settle inside that
    /// window must not send the same ids to the server twice.
    @ObservationIgnored private var scrollReadInFlight: Set<String> = []

    /// A row counts as read once its head has left the top of the viewport by this fraction of
    /// its own height. A card that has merely poked 25% *into* the list is a header plus one
    /// line of body — that is not a message anybody read.
    private static let scrollReadHeadline: CGFloat = 0.25
    /// Judged one layout pass after the reports stop arriving: that is what "the scroll came to
    /// rest" looks like from here, and it does not depend on a scroll-phase callback firing.
    private static let scrollSettleTime: TimeInterval = 0.15

    /// Rows report their frame in the list's coordinate space as SwiftUI lays them out: y = 0
    /// is the top of the viewport, so a negative `minY` is a row head that has left the window.
    /// Nothing is judged per card — the report only keeps the measurement current and restarts
    /// the settle. `@ObservationIgnored` is what stops a write per layout pass from invalidating
    /// the very list being measured.
    func reportRowFrame(_ id: String, frame: CGRect) {
        guard rowFrames[id] != frame else { return }
        rowFrames[id] = frame
        scrollSettleTask?.cancel()
        scrollSettleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.scrollSettleTime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.commitScrollReads()
        }
    }

    /// Deepest row whose head has left the viewport, nil when none has. Judging the whole list
    /// at rest instead of per card is what makes the read state one contiguous block: a fast
    /// flick never lays out the rows it blows past, so they have no frame to report, yet
    /// everything above the deepest measured row has been scrolled through.
    private var scrolledPastDepth: Int? {
        var deepest: Int?
        for (index, row) in messages.enumerated() {
            guard let frame = rowFrames[row.id] else { continue }
            if frame.minY <= -Self.scrollReadHeadline * frame.height { deepest = index }
        }
        return deepest
    }

    private func commitScrollReads() async {
        guard let depth = scrolledPastDepth else { return }
        // The frontier holds back a message that landed while the window was up: an automatic
        // read must never swallow one the user is still waiting for.
        let rows = messages[...depth].filter {
            !$0.isRead && !scrollReadInFlight.contains($0.id) && $0.message.time <= scrollReadFrontier
        }
        guard !rows.isEmpty else { return }
        let ids = rows.map(\.id)
        scrollReadInFlight.formUnion(ids)
        defer { scrollReadInFlight.subtract(ids) }
        await markRowsRead(rows)
    }

    private func markRowsRead(_ rows: [StoredMessage]) async {
        let flipped = (try? await store.markReadBatch(rows)) ?? []
        guard !flipped.isEmpty else { return }

        // Flip the rows on screen in place instead of re-reading the page: the scroll position
        // stays put and 仅看未读 cannot pull the row out from under the pointer.
        let read = Set(flipped.map(\.id))
        for index in messages.indices where read.contains(messages[index].id) {
            messages[index].isRead = true
        }

        for ref in Set(flipped.map(\.topicRef)) {
            postStoreChange(for: ref, countsOnly: true)
        }
        NotificationManager.shared.revoke(messageIDs: flipped.map { $0.message.id })

        for (ref, group) in Dictionary(grouping: flipped, by: { $0.topicRef }) {
            await MessageActionService.markAllReadOnServer(
                serverURL: ref.serverURL,
                topic: ref.topic,
                targets: group.map { (sequenceID: $0.message.sequenceId, messageID: $0.message.id) },
                authToken: configStore.authToken(forServer: ref.serverURL),
                session: serverMarkReadSession
            )
        }
    }

    func markAllRead(for ref: TopicRef) {
        Task { [weak self] in
            guard let self else { return }
            await markTopicRead(for: ref, syncToServer: true)
        }
    }

    /// Clears unread across every topic at once, this device and the server alike. The mark
    /// is batched (`MessageActionService.sequenceIDsPerRequest` ids per request) and capped per
    /// topic, so a huge catch-up backlog costs a handful of requests instead of thousands.
    func markEverythingRead() {
        let refs = unreadCounts.filter { $0.value > 0 }.map(\.key)
        guard !refs.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            for ref in refs {
                await markTopicRead(for: ref, syncToServer: true)
            }
        }
    }

    /// Marks every topic of one server read — the merged view's version of 全部已读, since
    /// the per-topic button can only ever see one topic.
    func markServerAllRead(serverURL: String) {
        let refs = unreadCounts.filter { $0.key.serverURL == serverURL && $0.value > 0 }.map(\.key)
        guard !refs.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            for ref in refs {
                await markTopicRead(for: ref, syncToServer: true)
            }
        }
    }

    private func markTopicRead(for ref: TopicRef, syncToServer: Bool) async {
        // Collect the unread set first: after markAllRead it is gone.
        let targets = await messageTargets(for: ref, onlyUnread: true)
        try? await store.markAllRead(serverURL: ref.serverURL, topic: ref.topic)
        postStoreChange(for: ref)
        NotificationManager.shared.revoke(messageIDs: targets.map { $0.messageID })
        guard syncToServer else { return }

        // Sync at most the newest `serverMarkReadCap` targets; older unread messages on
        // other devices converge when the user reads them individually there.
        let synced = await MessageActionService.markAllReadOnServer(
            serverURL: ref.serverURL,
            topic: ref.topic,
            targets: Array(targets.prefix(Self.serverMarkReadCap)),
            authToken: configStore.authToken(forServer: ref.serverURL),
            session: serverMarkReadSession
        )
        let total = targets.count
        guard synced < total else {
            serverSyncNotice = nil
            return
        }
        if total > Self.serverMarkReadCap {
            serverSyncNotice = LF("本地已全部标为已读；服务器已同步 %1$d 条，其余超出单次上限 %2$d 条未同步（限速保护）。", synced, Self.serverMarkReadCap)
        } else {
            serverSyncNotice = LF("本地已全部标为已读；服务器同步在 %1$d/%2$d 处停止（离线或无写入权限）。", synced, total)
        }
    }

    /// Non-deleted messages of a topic, paged by time cursor.
    private func messageTargets(for ref: TopicRef, onlyUnread: Bool) async -> [(sequenceID: String?, messageID: String)] {
        var targets: [(sequenceID: String?, messageID: String)] = []
        var seen: Set<String> = []
        var cursor: PageCursor?
        while true {
            let page = (try? await store.messages(
                serverURL: ref.serverURL, topic: ref.topic,
                limit: Self.pageSize, before: cursor, onlyUnread: onlyUnread
            )) ?? []
            for stored in page where seen.insert(stored.message.id).inserted {
                targets.append((stored.message.sequenceId, stored.message.id))
            }
            guard page.count == Self.pageSize, let oldest = page.last else { break }
            cursor = oldest.cursor
        }
        return targets
    }

    func delete(_ stored: StoredMessage) {
        let ref = stored.topicRef
        Task { [weak self] in
            guard let self else { return }
            // 1. Local tombstone first (authoritative for the UI).
            _ = try? await self.store.tombstoneMessage(
                serverURL: ref.serverURL, topic: ref.topic, messageID: stored.message.id
            )
            NotificationManager.shared.revoke(messageIDs: [stored.message.id])
            // 2. Best-effort server delete (silent on failure).
            await MessageActionService.deleteOnServer(
                serverURL: ref.serverURL,
                topic: ref.topic,
                sequenceID: stored.message.sequenceId,
                messageID: stored.message.id,
                authToken: configStore.authToken(forServer: ref.serverURL)
            )
            self.postStoreChange(for: ref)
        }
    }

    /// Clears a topic's messages. `withServer` also deletes them from the server cache, which
    /// is what makes them disappear on the other devices too; the delete route only takes one
    /// id per request, so it is capped and the remainder is reported in `serverSyncNotice`.
    func clearTopic(_ ref: TopicRef, withServer: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            let targets = await self.messageTargets(for: ref, onlyUnread: false)
            try? await self.store.tombstoneAll(serverURL: ref.serverURL, topic: ref.topic)
            self.confirmClearTopic = nil
            self.postStoreChange(for: ref)
            NotificationManager.shared.revoke(messageIDs: targets.map { $0.messageID })
            guard withServer else { return }

            let synced = await MessageActionService.deleteAllOnServer(
                serverURL: ref.serverURL,
                topic: ref.topic,
                targets: Array(targets.prefix(Self.serverClearCap)),
                authToken: configStore.authToken(forServer: ref.serverURL),
                session: self.serverMarkReadSession
            )
            let total = targets.count
            if synced == total {
                self.serverSyncNotice = nil
            } else if total > Self.serverClearCap {
                self.serverSyncNotice = LF("本地已全部清空；服务器已删除 %1$d 条，其余超出单次上限 %2$d 条未删除（限速保护）。", synced, Self.serverClearCap)
            } else {
                self.serverSyncNotice = LF("本地已全部清空；服务器删除在 %1$d/%2$d 处停止（离线或无写入权限）。", synced, total)
            }
        }
    }

    // MARK: - Server topic browser

    /// Fetches `GET /v1/topics` for every configured server and merges the result with the
    /// current subscriptions. Topics the server has no cached messages for are listed as
    /// `goneOnServer` — the server's list only covers what is still in its cache.
    func loadServerTopics() {
        guard let config = configStore.config, !config.servers.isEmpty else {
            serverTopics = [:]
            serverTopicsError = L("尚未配置服务器")
            return
        }
        guard !isLoadingServerTopics else { return }
        isLoadingServerTopics = true
        serverTopicsError = nil

        Task { [weak self] in
            guard let self else { return }
            var grouped: [String: [ServerTopicEntry]] = [:]
            var problems: [String] = []
            for server in config.servers {
                let token = self.configStore.authToken(forServer: server.url)
                do {
                    let live = try await self.topicsFetcher(server.url, token)
                    grouped[server.url] = Self.browserEntries(
                        serverURL: server.url, live: live, subscribed: server.topics.map { $0.name }
                    )
                } catch {
                    problems.append("\(server.url)：\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                }
            }
            self.serverTopics = grouped
            self.serverTopicsError = problems.isEmpty ? nil : problems.joined(separator: "\n")
            self.isLoadingServerTopics = false
        }
    }

    /// Live ids first (alphabetical), then the subscribed-but-gone ones.
    static func browserEntries(
        serverURL: String,
        live: [String],
        subscribed: [String]
    ) -> [ServerTopicEntry] {
        let subscribedSet = Set(subscribed)
        let entries = live.map {
            ServerTopicEntry(
                serverURL: serverURL, topic: $0,
                status: subscribedSet.contains($0) ? .subscribed : .available
            )
        }
        let gone = subscribedSet.subtracting(live).sorted().map {
            ServerTopicEntry(serverURL: serverURL, topic: $0, status: .goneOnServer)
        }
        return entries.sorted { $0.topic < $1.topic } + gone
    }

    /// Subscribes to a server topic by adding it to the config file; `ConfigWatcher` picks the
    /// change up and the connection to that server is rebuilt with the new topic.
    func subscribe(serverURL: String, topic: String) {
        var didApply = false
        applyToConfig(serverURL: serverURL) { server in
            guard !server.topics.contains(where: { $0.name == topic }) else { return server }
            didApply = true
            return ServerConfig(
                url: server.url, token: server.token,
                topics: server.topics + [TopicConfig(name: topic)],
                allowedSchemes: server.allowedSchemes,
                allowedDomains: server.allowedDomains,
                fetchMissed: server.fetchMissed
            )
        }
        if didApply { updateRowStatus(serverURL: serverURL, topic: topic, to: .subscribed) }
        refreshSidebar()
    }

    /// Drops a subscription. `pruneOrphanedHistory` removes the local history on the reload,
    /// so the unread badge of a topic nobody subscribed to any more cannot linger.
    func unsubscribe(serverURL: String, topic: String) {
        applyToConfig(serverURL: serverURL) { server in
            ServerConfig(
                url: server.url, token: server.token,
                topics: server.topics.filter { $0.name != topic },
                allowedSchemes: server.allowedSchemes,
                allowedDomains: server.allowedDomains,
                fetchMissed: server.fetchMissed
            )
        }
        updateRowStatus(serverURL: serverURL, topic: topic, to: .available)
        refreshSidebar()
    }

    /// Applies a config change through the store. The store updates memory, writes the
    /// file and fires its `.internalSave` change, which the running coordinator uses to
    /// reconcile connections directly — no file event round-trip required.
    private func applyToConfig(serverURL: String, _ transform: (ServerConfig) -> ServerConfig) {
        do {
            try configStore.replacingTopics(serverURL: serverURL, transform)
        } catch {
            serverTopicsError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Reflects a subscription change in the loaded browser rows, so a topic the user just
    /// subscribed to shows as subscribed without re-querying the server.
    private func updateRowStatus(serverURL: String, topic: String, to status: ServerTopicEntry.Status) {
        guard var entries = serverTopics[serverURL],
              let index = entries.firstIndex(where: { $0.topic == topic }) else { return }
        entries[index].status = status
        serverTopics[serverURL] = entries
    }

    /// Drops every local row of a topic the server no longer holds. The subscription stays —
    /// the topic may simply have run its messages down to expiry.
    func clearLocalHistory(serverURL: String, topic: String) {
        let ref = TopicRef(serverURL: serverURL, topic: topic)
        Task { [weak self] in
            guard let self else { return }
            let ids = ((try? await self.store.messages(
                serverURL: serverURL, topic: topic, limit: 1000
            )) ?? []).map { $0.message.id }
            NotificationManager.shared.revoke(messageIDs: ids)
            try? await self.store.deleteTopic(serverURL: serverURL, topic: topic)
            self.postStoreChange(for: ref)
        }
    }

    /// `DELETE /v1/topics/{topic}`: purges the server's cached messages and attachments, then
    /// the local history of that topic, since keeping rows the server threw away would only
    /// resurrect them on the next full sync.
    func retireTopic(_ ref: TopicRef) {
        let token = configStore.authToken(forServer: ref.serverURL)
        Task { [weak self] in
            guard let self else { return }
            defer { self.confirmRetireTopic = nil }
            do {
                _ = try await self.topicRetrier(ref.serverURL, ref.topic, token)
            } catch {
                self.serverTopicsError = LF("退役 %1$@ 失败：%2$@", self.label(for: ref), (error as? LocalizedError)?.errorDescription ?? "\(error)")
                return
            }
            NotificationManager.shared.revoke(
                messageIDs: (try? await self.store.messages(
                    serverURL: ref.serverURL, topic: ref.topic, limit: 1000
                ))?.map { $0.message.id } ?? []
            )
            try? await self.store.deleteTopic(serverURL: ref.serverURL, topic: ref.topic)
            self.postStoreChange(for: ref)
            self.loadServerTopics()
        }
    }

    func copyMessage(_ stored: StoredMessage) {
        let text = stored.message.message ?? ""
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openURL(_ urlString: String, serverURL: String) {
        guard let url = URL(string: urlString) else { return }
        MessageActionService.openSecurely(
            url,
            serverBaseURL: serverURL,
            serverConfig: configStore.serverConfig(forURL: serverURL)
        )
    }

    // MARK: - Attachments (audit 3.5)

    /// Test seam for attachment downloads.
    var attachmentDirectoryOverride: URL?
    var attachmentSession: URLSession = .shared

    /// Downloads the attachment (or reuses the cached file) and opens it with the
    /// default application; clicking again after a failure retries.
    func downloadAndOpen(_ stored: StoredMessage) {
        guard let attachment = stored.message.attachment,
              attachmentStates[attachment.url] != .downloading else { return }
        attachmentStates[attachment.url] = .downloading
        let serverURL = stored.serverURL
        Task { [weak self] in
            guard let self else { return }
            do {
                let fileURL = try await AttachmentService.download(
                    attachment: attachment,
                    serverURL: serverURL,
                    authToken: configStore.authToken(forServer: serverURL),
                    to: self.attachmentDirectoryOverride,
                    session: self.attachmentSession
                )
                self.attachmentStates[attachment.url] = nil
                NSWorkspace.shared.open(fileURL)
            } catch let error as AttachmentService.AttachmentError {
                self.attachmentStates[attachment.url] = .failed(reason: error.errorDescription ?? L("下载失败"))
            } catch {
                self.attachmentStates[attachment.url] = .failed(reason: error.localizedDescription)
            }
        }
    }

    func execute(action: NtfyMessage.NtfyAction, serverURL: String) {
        MessageActionService.execute(
            action: action,
            serverURL: serverURL,
            serverConfig: configStore.serverConfig(forURL: serverURL)
        )
    }

    // MARK: - Live updates (audit B3: bus + Task coalescing)

    private func noteStoreChange(topicRef ref: TopicRef?, countsOnly: Bool = false) {
        if let ref {
            if countsOnly {
                pendingCountsOnlyTopics.insert(ref)
            } else {
                pendingStoreChangeTopics.insert(ref)
            }
        } else {
            // A change that names no topic (retention, a whole-store edit) can affect anything.
            pendingStoreChangeIsGlobal = true
        }
        storeChangeSettleTask?.cancel()
        storeChangeSettleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.storeChangeSettleTime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushStoreChanges()
        }
    }

    private func flushStoreChanges() {
        let refs = pendingStoreChangeTopics
        let countsOnlyRefs = pendingCountsOnlyTopics
        let isGlobal = pendingStoreChangeIsGlobal
        pendingStoreChangeTopics.removeAll()
        pendingCountsOnlyTopics.removeAll()
        pendingStoreChangeIsGlobal = false
        guard !refs.isEmpty || !countsOnlyRefs.isEmpty || isGlobal else { return }

        refreshSidebar()
        // A counts-only change is the list's own edit coming back around: the rows on screen
        // were already flipped in place, so re-reading them would only swap the array under
        // the user's scroll position (and drop the ones 仅看未读 no longer matches).
        let reloadable = isGlobal || !refs.isEmpty
        guard reloadable else { return }
        switch selection {
        case .topic(let selected):
            if isGlobal || refs.contains(selected) {
                reloadMessages(liveUpdate: true)
            }
        case .serverAll(let serverURL):
            // The merged list is only interested in changes under its own server.
            if isGlobal || refs.contains(where: { $0.serverURL == serverURL }) {
                reloadMessages(liveUpdate: true)
            }
        case nil:
            break
        }
    }

    private func postStoreChange(for ref: TopicRef, countsOnly: Bool = false) {
        changeBus.post(topicRef: ref, countsOnly: countsOnly)
    }
}
