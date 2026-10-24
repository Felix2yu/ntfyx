import SwiftUI
import AppKit

/// Root view of the notification history window:
/// sidebar with topics (grouped by server, unread badges) + message list.
public struct HistoryView: View {
    @Bindable var viewModel: HistoryViewModel
    @State private var isBrowserPresented = false

    /// Declared sidebar width band; SwiftUI owns the live width and scene state
    /// restoration (no more AppKit divider tracking).
    private let sidebarMin: CGFloat = 160
    private let sidebarIdeal: CGFloat = 260
    private let sidebarMax: CGFloat = 600

    public init(viewModel: HistoryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: sidebarMin,
                                                ideal: sidebarIdeal,
                                                max: sidebarMax)
        } detail: {
            detailColumn
                // Detail-column ideal (690 = 950 window − 260 sidebar) makes the
                // Window scene open at its defaultSize instead of shrink-to-fit.
                .frame(
                    minWidth: 460, idealWidth: 690, maxWidth: .infinity,
                    minHeight: 480, idealHeight: 620, maxHeight: .infinity
                )
                .navigationSplitViewColumnWidth(min: 460, ideal: 690, max: .infinity)
        }
        // idealWidth/Height give the SwiftUI WindowGroup scene its first-launch size
        // (950×620, matching the old hosting window); the min band matches the scene's.
        .frame(
            minWidth: 720, idealWidth: 950, maxWidth: .infinity,
            minHeight: 480, idealHeight: 620, maxHeight: .infinity
        )
        .toolbar {
            // The system supplies the official sidebar toggle in the toolbar.
            ToolbarItem(placement: .primaryAction) {
                TextField(L("全局搜索"), text: $viewModel.globalQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .help(L("在所有主题的标题、正文与名称中搜索"))
            }
        }
        .onAppear {
            viewModel.refreshSidebar()
        }
        .sheet(isPresented: $isBrowserPresented) {
            TopicBrowserView(viewModel: viewModel)
        }
        .confirmationDialog(
            LF("退役主题「%@」？", viewModel.confirmRetireTopic.map { viewModel.label(for: $0) } ?? ""),
            isPresented: Binding(
                get: { viewModel.confirmRetireTopic != nil },
                set: { if !$0 { viewModel.confirmRetireTopic = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("退役并从服务器删除"), role: .destructive) {
                if let ref = viewModel.confirmRetireTopic {
                    viewModel.retireTopic(ref)
                }
            }
            Button(L("取消"), role: .cancel) {
                viewModel.confirmRetireTopic = nil
            }
        } message: {
            Text(L("服务器会丢弃该主题的全部缓存消息与附件，其他设备也会随之清空；服务器上的主题配置不会被改动。本机的历史与订阅保留。"))
        }
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detailColumn: some View {
        if viewModel.isGlobalSearchActive {
            globalSearchResults
        } else if let serverURL = viewModel.selectedServerAll {
            ServerHistoryView(viewModel: viewModel, serverURL: serverURL)
                .id(serverURL)  // reset scroll state when switching servers
        } else if let ref = viewModel.selectedTopic {
            TopicDetailView(viewModel: viewModel, topicRef: ref)
                .id(ref)  // reset scroll state when switching topics
        } else {
            Text(L("选择一个主题查看历史消息"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding<HistoryViewModel.Selection?>(
            get: { viewModel.selection },
            set: { viewModel.selection = $0 }
        )) {
            if viewModel.groups.isEmpty {
                Text(L("未配置服务器或主题"))
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.groups) { group in
                Section(group.url) {
                    serverAllRow(group.url)
                        .tag(HistoryViewModel.Selection.serverAll(group.url))
                    ForEach(group.topics) { entry in
                        topicRow(entry)
                            .tag(HistoryViewModel.Selection.topic(entry.ref))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if viewModel.totalUnread > 0 {
                    HStack {
                        Text(LF("%d 条未读", viewModel.totalUnread))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            viewModel.markEverythingRead()
                        } label: {
                            Label(L("全部已读"), systemImage: "checkmark.circle")
                        }
                        .font(.footnote)
                        .help(L("把所有服务器上全部主题的消息标为已读"))
                    }
                }
                Button {
                    isBrowserPresented = true
                    viewModel.loadServerTopics()
                } label: {
                    Label(L("服务器主题"), systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .help(L("查看服务器上有缓存的主题，点订阅即可加入"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// First row of every server section: the merged timeline of that server's topics.
    private func serverAllRow(_ serverURL: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(L("全部主题"))
                .lineLimit(1)
            Spacer()
            unreadBadge(viewModel.unread(forServer: serverURL))
        }
    }

    private func topicRow(_ entry: HistoryViewModel.TopicEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: entry.iconSymbol ?? "bell")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(entry.label)
                .lineLimit(1)
                .help(entry.label == entry.ref.topic ? Text(verbatim: "") : Text(LF("主题 id：%@", entry.ref.topic)))
            Spacer()
            unreadBadge(entry.unread)
        }
        .contextMenu {
            Button(L("从服务器退役…"), role: .destructive) {
                viewModel.confirmRetireTopic = entry.ref
            }
        }
    }

    @ViewBuilder
    private func unreadBadge(_ unread: Int) -> some View {
        if unread > 0 {
            Text("\(unread)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.accentColor))
        }
    }

    // MARK: - Global search results

    private var globalSearchResults: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(viewModel.isGlobalSearching
                    ? L("搜索中…")
                    : viewModel.globalResults.count >= HistoryViewModel.globalSearchCap
                        ? LF("前 %d 条结果", viewModel.globalResults.count)
                        : LF("%d 条结果", viewModel.globalResults.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("退出搜索")) {
                    viewModel.globalQuery = ""
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if viewModel.globalResults.isEmpty {
                VStack(spacing: 8) {
                    if viewModel.isGlobalSearching {
                        ProgressView()
                    } else {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text(L("没有匹配的消息"))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.globalResults) { hit in
                            GlobalSearchResultRow(
                                hit: hit,
                                topicLabel: viewModel.label(for: hit.topicRef)
                            ) {
                                viewModel.openGlobalResult(hit)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Sheet listing what each configured server currently has cached: unsubscribed topics get a
/// subscribe button, subscribed-but-purged ones get a local-history cleanup.
private struct TopicBrowserView: View {
    let viewModel: HistoryViewModel
    @Environment(\.dismiss) private var dismiss
    /// Topic whose server-cache purge the user is confirming.
    @State private var pendingRetire: HistoryViewModel.ServerTopicEntry?
    private static let windowWidth: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("服务器主题"))
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.loadServerTopics()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoadingServerTopics)
                .help(L("重新向服务器查询主题列表"))
                Button(L("完成")) {
                    dismiss()
                }
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let error = viewModel.serverTopicsError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    ForEach(browserSections) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.serverURL)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(section.entries) { entry in
                                row(entry)
                            }
                        }
                    }
                    if !viewModel.isLoadingServerTopics && browserSections.isEmpty {
                        Text(L("没有查询到主题"))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            if viewModel.isLoadingServerTopics {
                Divider()
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("正在查询服务器主题…"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
        }
        .frame(width: Self.windowWidth, height: 420)
        .confirmationDialog(
            LF("清空主题「%@」的服务器缓存？", pendingRetire.map { viewModel.label(for: TopicRef(serverURL: $0.serverURL, topic: $0.topic)) } ?? ""),
            isPresented: Binding(
                get: { pendingRetire != nil },
                set: { if !$0 { pendingRetire = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("从服务器删除"), role: .destructive) {
                if let entry = pendingRetire {
                    viewModel.retireTopic(TopicRef(serverURL: entry.serverURL, topic: entry.topic))
                }
                pendingRetire = nil
            }
            Button(L("取消"), role: .cancel) {
                pendingRetire = nil
            }
        } message: {
            Text(L("服务器会丢弃该主题的全部缓存消息与附件，其他设备也会随之清空；有新消息发布时主题会重新出现在列表里。"))
        }
        .task {
            if viewModel.serverTopics.isEmpty { viewModel.loadServerTopics() }
        }
    }

    private var browserSections: [BrowserSection] {
        viewModel.serverTopics.keys.sorted().map { url in
            BrowserSection(serverURL: url, entries: viewModel.serverTopics[url] ?? [])
        }
    }

    private struct BrowserSection: Identifiable {
        let serverURL: String
        let entries: [HistoryViewModel.ServerTopicEntry]
        var id: String { serverURL }
    }

    @ViewBuilder
    private func row(_ entry: HistoryViewModel.ServerTopicEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon(entry.status))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(rowLabel(entry))
                .lineLimit(1)
            Spacer()
            trailing(entry)
        }
        .padding(.vertical, 2)
    }

    /// Subscribed rows show the user's 备注; the rest can only show the server's name.
    private func rowLabel(_ entry: HistoryViewModel.ServerTopicEntry) -> String {
        viewModel.label(for: TopicRef(serverURL: entry.serverURL, topic: entry.topic))
    }

    private func statusIcon(_ status: HistoryViewModel.ServerTopicEntry.Status) -> String {
        switch status {
        case .subscribed: return "bell.fill"
        case .available: return "bell.and.waves.left.and.materialize"
        case .goneOnServer: return "bell.slash"
        }
    }

    @ViewBuilder
    private func trailing(_ entry: HistoryViewModel.ServerTopicEntry) -> some View {
        let serverURL = entry.serverURL
        let topic = entry.topic
        switch entry.status {
        case .subscribed:
            Text(L("已订阅"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                viewModel.unsubscribe(serverURL: serverURL, topic: topic)
            } label: {
                Image(systemName: "bell.slash")
            }
            .buttonStyle(.borderless)
            .help(L("取消订阅（本机会一并清掉该主题的历史）"))
        case .available:
            Button(L("订阅")) {
                viewModel.subscribe(serverURL: serverURL, topic: topic)
            }
            Button {
                pendingRetire = entry
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L("清空该主题在服务器上的缓存，需对该主题有写入权限"))
        case .goneOnServer:
            Text(L("服务器已无缓存"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if entry.hasLocalHistory {
                Button(L("清除本地历史")) {
                    viewModel.clearLocalHistory(serverURL: serverURL, topic: topic)
                }
            }
            Button {
                viewModel.unsubscribe(serverURL: serverURL, topic: topic)
            } label: {
                Image(systemName: "bell.slash")
            }
            .buttonStyle(.borderless)
            .help(L("取消订阅（本机会一并清掉该主题的历史）"))
        }
    }
}

/// One row in the global search result list; clicking it opens the hit's topic.
private struct GlobalSearchResultRow: View {
    let hit: StoredMessage
    let topicLabel: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(topicLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(hit.serverURL)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    Text(MessageActionService.formattedTime(hit.time))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let title = hit.message.title, !title.isEmpty {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                if let body = hit.message.message, !body.isEmpty {
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hit.isRead ? Color.clear : Color.accentColor.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(hit.isRead ? Color.secondary.opacity(0.15) : Color.accentColor.opacity(0.3),
                                  lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(LF("打开主题「%@」", topicLabel))
    }
}
