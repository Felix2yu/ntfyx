import Foundation
import SwiftUI
import AppKit
import Combine

extension Notification.Name {
    /// Posted (on any queue) after the history store changed for a topic.
    /// userInfo["topicRef"] holds the affected TopicRef.
    static let historyStoreDidChange = Notification.Name("historyStoreDidChange")
}

/// View model for the notification history window.
@MainActor
final class HistoryViewModel: ObservableObject {

    struct TopicEntry: Identifiable, Hashable {
        let ref: TopicRef
        let iconSymbol: String?
        var unread: Int
        var id: String { "\(ref.serverURL)|\(ref.topic)" }
    }

    struct ServerGroup: Identifiable {
        let url: String
        var topics: [TopicEntry]
        var id: String { url }
    }

    /// One row of the server topic browser: every topic id the server has cached messages
    /// for, plus every subscribed topic it no longer has (so a retired or fully expired topic
    /// cannot leave local history hanging with nobody left to clear it).
    struct ServerTopicEntry: Identifiable, Hashable {
        enum Status: Equatable {
            case subscribed        // live on the server, already subscribed here
            case available         // live on the server, not subscribed yet
            case goneOnServer      // subscribed here, but the server has no cached messages
        }

        let serverURL: String
        let topic: String
        var status: Status
        var id: String { "\(serverURL)|\(topic)" }
    }

    static let pageSize = 100
    static let globalSearchCap = 200

    /// Upper bound for server-synced targets in one mark-all-read. The server publishes a
    /// `message_clear` per target and each one counts against the visitor's message budget,
    /// so a huge unread set must not replay all of it. Requests stay bounded because the
    /// service packs up to `MessageActionService.sequenceIDsPerRequest` ids per call.
    static let serverMarkReadCap = 500

    /// Upper bound for server-deleted messages when clearing a topic. Unlike `/read` the
    /// delete route accepts one id per request, so a large topic is capped and reported.
    static let serverClearCap = 100

    // MARK: - Published state

    @Published var groups: [ServerGroup] = []
    @Published var selectedTopic: TopicRef? {
        didSet {
            guard oldValue != selectedTopic else { return }
            handleSelectionChange()
        }
    }
    @Published var messages: [StoredMessage] = []
    @Published var unreadCounts: [TopicRef: Int] = [:]
    @Published var onlyUnread = false
    @Published var searchText = ""

    // MARK: - Global search state (across all topics; replaces the detail pane)

    @Published var globalQuery = ""
    @Published var globalResults: [StoredMessage] = []
    @Published var isGlobalSearching = false

    @Published var hasMoreMessages = false
    @Published var isLoadingOlder = false
    @Published var confirmClearTopic: TopicRef?
    /// Explains partial server sync after a capped/rejected mark-all-read or topic clear;
    /// shown in the footer.
    @Published var serverSyncNotice: String?

    // MARK: - Server topic browser

    /// Server-origin topics of every configured server, grouped by server URL: the ones the
    /// server still has cached messages for, plus the subscribed ones it no longer has.
    @Published var serverTopics: [String: [ServerTopicEntry]] = [:]
    @Published var isLoadingServerTopics = false
    @Published var serverTopicsError: String?
    /// Topic the user asked to retire on the server; drives the confirmation dialog.
    @Published var confirmRetireTopic: TopicRef?
    /// Per-attachment download state, keyed by attachment URL.
    enum AttachmentState: Equatable {
        case downloading
        case failed(reason: String)
    }
    @Published var attachmentStates: [String: AttachmentState] = [:]

    // MARK: - Dependencies

    private let store: MessageStore
    let syncService: HistorySyncService
    /// Test seam: session used for server mark-read requests.
    var serverMarkReadSession: URLSession = .shared
    /// Test seams for the topic browser, so subscribing can be exercised without a server.
    var topicsFetcher: @Sendable (String, String?) async throws -> [String] = {
        try await MessageActionService.fetchServerTopics(
            serverURL: $0, authToken: $1, session: .shared
        )
    }
    var topicRetrier: @Sendable (String, String, String?) async throws -> Int = {
        try await MessageActionService.retireTopic(
            serverURL: $0, topic: $1, authToken: $2, session: .shared
        )
    }
    private var searchTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var globalSearchGeneration = 0
    private var cancellables: Set<AnyCancellable> = []

    /// Store changes arrive one per message (live) or per replay chunk, and each one used to
    /// mean a sidebar aggregate plus a page reload. They are collected for a settle window and
    /// applied once, keeping the topics they named so the open topic still refreshes.
    static let storeChangeSettleTime: TimeInterval = 0.25
    private var pendingStoreChangeTopics: Set<TopicRef> = []
    private var pendingStoreChangeIsGlobal = false
    private var storeChangeTimer: Timer?

    // MARK: - Init

    init(store: MessageStore, syncService: HistorySyncService) {
        self.store = store
        self.syncService = syncService

        // Live updates: the service layer posts store changes; refresh relevant parts.
        NotificationCenter.default.publisher(for: .historyStoreDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.noteStoreChange(notification)
            }
            .store(in: &cancellables)

        // Debounced search.
        $searchText
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadMessages()
            }
            .store(in: &cancellables)

        $globalQuery
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] query in
                self?.runGlobalSearch(query)
            }
            .store(in: &cancellables)

        refreshSidebar()
    }

    // MARK: - Sidebar

    func refreshSidebar() {
        Task { [weak self] in
            guard let self else { return }
            let counts = (try? await self.store.unreadCountsByTopic()) ?? [:]
            self.unreadCounts = counts

            var newGroups: [ServerGroup] = []
            if let config = ConfigManager.shared.config {
                for server in config.servers {
                    let entries = server.topics.map { topic in
                        TopicEntry(
                            ref: TopicRef(serverURL: server.url, topic: topic.name),
                            iconSymbol: topic.iconSymbol,
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

    func unread(for ref: TopicRef) -> Int {
        unreadCounts[ref] ?? 0
    }

    // MARK: - Selection & messages

    func selectTopic(_ ref: TopicRef?) {
        selectedTopic = ref
    }

    private func handleSelectionChange() {
        serverSyncNotice = nil
        reloadMessages()
        if let ref = selectedTopic {
            Task { [weak self] in
                guard let self else { return }
                await self.syncService.syncIncremental(ref)
                self.refreshSidebar()
                self.reloadMessages()
            }
        }
    }

    func reloadMessages() {
        guard let ref = selectedTopic else {
            messages = []
            hasMoreMessages = false
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
                    serverURL: ref.serverURL,
                    topic: ref.topic,
                    limit: Self.pageSize,
                    before: nil,
                    onlyUnread: onlyUnread,
                    searchText: searchText.isEmpty ? nil : searchText
                )
                guard generation == self.loadGeneration else { return }  // stale response
                self.messages = page
                self.hasMoreMessages = page.count >= Self.pageSize
            } catch {
                Log.error("History: failed to load messages: \(error)")
            }
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
        guard let ref = selectedTopic,
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
                    serverURL: ref.serverURL,
                    topic: ref.topic,
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
                authToken: ConfigManager.shared.getAuthToken(forServer: ref.serverURL)
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
            authToken: ConfigManager.shared.getAuthToken(forServer: ref.serverURL),
            session: serverMarkReadSession
        )
        let total = targets.count
        guard synced < total else {
            serverSyncNotice = nil
            return
        }
        if total > Self.serverMarkReadCap {
            serverSyncNotice = "本地已全部标为已读；服务器已同步 \(synced) 条，其余超出单次上限 \(Self.serverMarkReadCap) 条未同步（限速保护）。"
        } else {
            serverSyncNotice = "本地已全部标为已读；服务器同步在 \(synced)/\(total) 处停止（离线或无写入权限）。"
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
                authToken: ConfigManager.shared.getAuthToken(forServer: ref.serverURL)
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
                authToken: ConfigManager.shared.getAuthToken(forServer: ref.serverURL),
                session: self.serverMarkReadSession
            )
            let total = targets.count
            if synced == total {
                self.serverSyncNotice = nil
            } else if total > Self.serverClearCap {
                self.serverSyncNotice = "本地已全部清空；服务器已删除 \(synced) 条，其余超出单次上限 \(Self.serverClearCap) 条未删除（限速保护）。"
            } else {
                self.serverSyncNotice = "本地已全部清空；服务器删除在 \(synced)/\(total) 处停止（离线或无写入权限）。"
            }
        }
    }

    // MARK: - Server topic browser

    /// Fetches `GET /v1/topics` for every configured server and merges the result with the
    /// current subscriptions. Topics the server has no cached messages for are listed as
    /// `goneOnServer` — the server's list only covers what is still in its cache.
    func loadServerTopics() {
        guard let config = ConfigManager.shared.config, !config.servers.isEmpty else {
            serverTopics = [:]
            serverTopicsError = "尚未配置服务器"
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
                let token = ConfigManager.shared.getAuthToken(forServer: server.url)
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

    /// Applies a config change and reloads the service. The file write alone would already
    /// reach `ConfigWatcher`, except when the watcher could not be installed at launch.
    private func applyToConfig(serverURL: String, _ transform: (ServerConfig) -> ServerConfig) {
        do {
            try ConfigManager.replacingTopics(serverURL: serverURL, transform)
        } catch {
            serverTopicsError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return
        }
        serverTopicsError = nil
        CLI.ntfyAppInstance?.reloadConfig()
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
        let token = ConfigManager.shared.getAuthToken(forServer: ref.serverURL)
        Task { [weak self] in
            guard let self else { return }
            defer { self.confirmRetireTopic = nil }
            do {
                _ = try await self.topicRetrier(ref.serverURL, ref.topic, token)
            } catch {
                self.serverTopicsError = "退役 \(ref.topic) 失败：\((error as? LocalizedError)?.errorDescription ?? "\(error)")"
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
        MessageActionService.openSecurely(url, serverBaseURL: serverURL)
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
                    authToken: ConfigManager.shared.getAuthToken(forServer: serverURL),
                    to: self.attachmentDirectoryOverride,
                    session: self.attachmentSession
                )
                self.attachmentStates[attachment.url] = nil
                NSWorkspace.shared.open(fileURL)
            } catch let error as AttachmentService.AttachmentError {
                self.attachmentStates[attachment.url] = .failed(reason: error.errorDescription ?? "下载失败")
            } catch {
                self.attachmentStates[attachment.url] = .failed(reason: error.localizedDescription)
            }
        }
    }

    func execute(action: NtfyMessage.NtfyAction, serverURL: String) {
        MessageActionService.execute(action: action, serverURL: serverURL)
    }

    // MARK: - Live updates

    private func noteStoreChange(_ notification: Notification) {
        if let ref = notification.userInfo?["topicRef"] as? TopicRef {
            pendingStoreChangeTopics.insert(ref)
        } else {
            // A change that names no topic (retention, a whole-store edit) can affect anything.
            pendingStoreChangeIsGlobal = true
        }
        storeChangeTimer?.invalidate()
        storeChangeTimer = Timer.scheduledTimer(
            withTimeInterval: Self.storeChangeSettleTime, repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.flushStoreChanges() }
        }
    }

    private func flushStoreChanges() {
        storeChangeTimer = nil
        let refs = pendingStoreChangeTopics
        let isGlobal = pendingStoreChangeIsGlobal
        pendingStoreChangeTopics.removeAll()
        pendingStoreChangeIsGlobal = false
        guard !refs.isEmpty || isGlobal else { return }

        refreshSidebar()
        guard let selected = selectedTopic else { return }
        if isGlobal || refs.contains(selected) {
            reloadMessages()
        }
    }

    private func postStoreChange(for ref: TopicRef) {
        NotificationCenter.default.post(
            name: .historyStoreDidChange,
            object: nil,
            userInfo: ["topicRef": ref]
        )
    }
}
