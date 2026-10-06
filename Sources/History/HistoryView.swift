import SwiftUI
import AppKit

/// Root view of the notification history window:
/// sidebar with topics (grouped by server, unread badges) + message list.
struct HistoryView: View {
    @ObservedObject var viewModel: HistoryViewModel
    @State private var isBrowserPresented = false

    /// Column width to start at, read once at window creation. A stored value kept live
    /// would let SwiftUI re-assert the column while the user is dragging the divider.
    let initialSidebarWidth: Double

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: SidebarWidth.min,
                                                ideal: CGFloat(initialSidebarWidth),
                                                max: SidebarWidth.max)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            if viewModel.isGlobalSearchActive {
                globalSearchResults
            } else if let ref = viewModel.selectedTopic {
                TopicDetailView(viewModel: viewModel, topicRef: ref)
                    .id(ref)  // reset scroll state when switching topics
            } else {
                Text("选择一个主题查看历史消息")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .toolbar {
            // Own toggle pinned to the leading edge: the automatic one rides the
            // column divider, so it jumped to the far right when the sidebar hid.
            ToolbarItem(placement: .navigation) {
                Button {
                    NSApp.keyWindow?.firstResponder?
                        .tryToPerform(NSSelectorFromString("toggleSidebar:"), with: nil)
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("显示/隐藏侧栏")
            }
            ToolbarItem(placement: .primaryAction) {
                TextField("全局搜索", text: $viewModel.globalQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .help("在所有主题的标题、正文与名称中搜索")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.markEverythingRead()
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .help(viewModel.totalUnread > 0 ? "全部标记已读（\(viewModel.totalUnread) 条未读）" : "没有未读消息")
                .disabled(viewModel.totalUnread == 0)
            }
        }
        .onAppear {
            viewModel.refreshSidebar()
        }
        .sheet(isPresented: $isBrowserPresented) {
            TopicBrowserView(viewModel: viewModel)
        }
        .confirmationDialog(
            "退役主题「\(viewModel.confirmRetireTopic?.topic ?? "")」？",
            isPresented: Binding(
                get: { viewModel.confirmRetireTopic != nil },
                set: { if !$0 { viewModel.confirmRetireTopic = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("退役并从服务器删除", role: .destructive) {
                if let ref = viewModel.confirmRetireTopic {
                    viewModel.retireTopic(ref)
                }
            }
            Button("取消", role: .cancel) {
                viewModel.confirmRetireTopic = nil
            }
        } message: {
            Text("服务器会丢弃该主题的全部缓存消息与附件，其他设备也会随之清空；服务器上的主题配置不会被改动。本机的历史与订阅保留。")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding<TopicRef?>(
            get: { viewModel.selectedTopic },
            set: { viewModel.selectTopic($0) }
        )) {
            if viewModel.groups.isEmpty {
                Text("未配置服务器或主题")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.groups) { group in
                Section(group.url) {
                    ForEach(group.topics) { entry in
                        topicRow(entry)
                            .tag(entry.ref)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if viewModel.totalUnread > 0 {
                    Text("\(viewModel.totalUnread) 条未读")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isBrowserPresented = true
                    viewModel.loadServerTopics()
                } label: {
                    Label("服务器主题", systemImage: "antenna.radiowaves.left.and.right")
                }
                .font(.footnote)
                .help("查看服务器上有缓存的主题，点订阅即可加入")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func topicRow(_ entry: HistoryViewModel.TopicEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: entry.iconSymbol ?? "bell")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(entry.ref.topic)
                .lineLimit(1)
            Spacer()
            if entry.unread > 0 {
                Text("\(entry.unread)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
            }
        }
        .contextMenu {
            Button("从服务器退役…", role: .destructive) {
                viewModel.confirmRetireTopic = entry.ref
            }
        }
    }

    // MARK: - Global search results

    private var globalSearchResults: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(viewModel.isGlobalSearching
                    ? "搜索中…"
                    : viewModel.globalResults.count >= HistoryViewModel.globalSearchCap
                        ? "前 \(viewModel.globalResults.count) 条结果"
                        : "\(viewModel.globalResults.count) 条结果")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("退出搜索") {
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
                        Text("没有匹配的消息")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.globalResults) { hit in
                            GlobalSearchResultRow(hit: hit) {
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
    @ObservedObject var viewModel: HistoryViewModel
    @Environment(\.dismiss) private var dismiss
    /// Topic whose server-cache purge the user is confirming.
    @State private var pendingRetire: HistoryViewModel.ServerTopicEntry?
    private static let windowWidth: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("服务器主题")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.loadServerTopics()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoadingServerTopics)
                .help("重新向服务器查询主题列表")
                Button("完成") {
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
                        Text("没有查询到主题")
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
                    Text("正在查询服务器主题…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
        }
        .frame(width: Self.windowWidth, height: 420)
        .confirmationDialog(
            "清空主题「\(pendingRetire?.topic ?? "")」的服务器缓存？",
            isPresented: Binding(
                get: { pendingRetire != nil },
                set: { if !$0 { pendingRetire = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("从服务器删除", role: .destructive) {
                if let entry = pendingRetire {
                    viewModel.retireTopic(TopicRef(serverURL: entry.serverURL, topic: entry.topic))
                }
                pendingRetire = nil
            }
            Button("取消", role: .cancel) {
                pendingRetire = nil
            }
        } message: {
            Text("服务器会丢弃该主题的全部缓存消息与附件，其他设备也会随之清空；有新消息发布时主题会重新出现在列表里。")
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
            Text(entry.topic)
                .lineLimit(1)
            Spacer()
            trailing(entry)
        }
        .padding(.vertical, 2)
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
            Text("已订阅")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                viewModel.unsubscribe(serverURL: serverURL, topic: topic)
            } label: {
                Image(systemName: "bell.slash")
            }
            .buttonStyle(.borderless)
            .help("取消订阅（本机会一并清掉该主题的历史）")
        case .available:
            Button("订阅") {
                viewModel.subscribe(serverURL: serverURL, topic: topic)
            }
            Button {
                pendingRetire = entry
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("清空该主题在服务器上的缓存，需对该主题有写入权限")
        case .goneOnServer:
            Text("服务器已无缓存")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("清除本地历史") {
                viewModel.clearLocalHistory(serverURL: serverURL, topic: topic)
            }
        }
    }
}

/// One row in the global search result list; clicking it opens the hit's topic.
private struct GlobalSearchResultRow: View {
    let hit: StoredMessage
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(hit.topic)
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
        .help("打开主题「\(hit.topic)」")
    }
}
