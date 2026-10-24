import SwiftUI

/// The named coordinate space both history lists measure their rows in: y = 0 is the top of the
/// viewport, so a row with a negative `minY` has had its head scroll out of the window.
enum HistoryListSpace {
    static let name = "historyList"
}

/// Message list for a single topic, with toolbar operations
/// (mark all read, unread filter, search, full history sync, clear).
struct TopicDetailView: View {
    @Bindable var viewModel: HistoryViewModel
    let topicRef: TopicRef
    @AppStorage(AppSettings.scrollMarksReadKey) private var scrollMarksRead = false

    private var topicLabel: String { viewModel.label(for: topicRef) }
    private var idTooltip: Text { topicLabel == topicRef.topic ? Text(verbatim: "") : Text(LF("主题 id：%@", topicRef.topic)) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            messageList

            Divider()

            syncStatusFooter
        }
        .frame(minWidth: 560)
        .confirmationDialog(
            LF("清空主题「%@」的全部消息？", topicLabel),
            isPresented: Binding(
                get: { viewModel.confirmClearTopic != nil },
                set: { if !$0 { viewModel.confirmClearTopic = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("清空本地并从服务器删除"), role: .destructive) {
                if let ref = viewModel.confirmClearTopic {
                    viewModel.clearTopic(ref, withServer: true)
                }
            }
            Button(L("仅清空本地消息"), role: .destructive) {
                if let ref = viewModel.confirmClearTopic {
                    viewModel.clearTopic(ref)
                }
            }
            Button(L("取消"), role: .cancel) {
                viewModel.confirmClearTopic = nil
            }
        } message: {
            Text(L("「从服务器删除」会同步清掉其他设备上的这些消息；仅清空本地只影响这台 Mac，服务器缓存不变。"))
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(topicLabel)
                .font(.headline)
                .help(idTooltip)

            Spacer()

            Button {
                viewModel.markAllRead(for: topicRef)
            } label: {
                Label(L("全部已读"), systemImage: "checkmark.circle")
            }
            .help(L("将该主题全部消息标为已读"))

            Toggle(isOn: $viewModel.onlyUnread) {
                Text(L("仅看未读"))
                    .font(.callout)
            }
            .toggleStyle(.checkbox)

            TextField(L("搜索标题或正文"), text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)

            // 加载全部历史与清空都是低频重操作，收进溢出菜单给高频控件腾位置。
            Menu {
                Button {
                    viewModel.loadFullHistory()
                } label: {
                    Label(L("加载全部历史"), systemImage: "arrow.down.circle")
                }
                .disabled(isSyncing)

                Divider()

                Button(role: .destructive) {
                    viewModel.confirmClearTopic = topicRef
                } label: {
                    Label(L("清空…"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("更多操作"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if viewModel.messages.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.messages) { stored in
                            MessageCardView(
                                stored: stored,
                                attachmentState: stored.message.attachment.flatMap { viewModel.attachmentStates[$0.url] },
                                topicLabel: viewModel.label(for: topicRef),
                                onToggleRead: { viewModel.toggleRead(stored) },
                                onDelete: { viewModel.delete(stored) },
                                onCopy: { viewModel.copyMessage(stored) },
                                onOpenURL: { urlString in
                                    viewModel.openURL(urlString, serverURL: stored.serverURL)
                                },
                                onAction: { action in
                                    viewModel.execute(action: action, serverURL: stored.serverURL)
                                },
                                onDownloadAttachment: {
                                    viewModel.downloadAndOpen(stored)
                                }
                            )
                            .id(stored.id)
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named(HistoryListSpace.name))
                            } action: { frame in
                                if scrollMarksRead {
                                    viewModel.reportRowFrame(stored.id, frame: frame)
                                }
                            }
                            .onAppear {
                                if stored.id == viewModel.messages.last?.id {
                                    viewModel.loadOlder()
                                }
                            }
                        }

                        if viewModel.isLoadingOlder {
                            ProgressView()
                                .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
            .coordinateSpace(name: HistoryListSpace.name)
            .onAppear {
                // Always land on the newest message.
                if let first = viewModel.messages.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(L("暂无消息"))
                .foregroundStyle(.secondary)
            Text(L("新收到的通知会自动保存在这里；也可点击「加载全部历史」从服务器拉取。"))
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
    }

    // MARK: - Sync footer

    private var isSyncing: Bool {
        viewModel.syncService.isSyncing(topicRef)
    }

    private var syncStatusFooter: some View {
        let progress = viewModel.syncService.progress(for: topicRef)
        return HStack(spacing: 8) {
            if let notice = viewModel.serverSyncNotice {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(notice)
                Button {
                    viewModel.serverSyncNotice = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L("关闭提示"))
            } else {
                switch progress.phase {
                case .syncing:
                    ProgressView()
                        .controlSize(.small)
                    Text(LF("正在从服务器同步历史…（已接收 %d 条）", progress.receivedCount))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .rateLimited(let retryAfter):
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(LF("服务器限速，%d 秒后可重试", Int(retryAfter)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(L("重试")) {
                        viewModel.retrySync()
                    }
                    .font(.footnote)
                    .help(L("立即重新同步（限速到点后也会自动重试一次）"))
                case .failed(let message):
                    Image(systemName: "xmark.octagon")
                        .foregroundStyle(.red)
                    Text(LF("同步失败：%@", message))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button(L("重试")) {
                        viewModel.retrySync()
                    }
                    .font(.footnote)
                    .help(L("重新从服务器同步本主题历史"))
                case .completed(let count):
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text(LF("同步完成，共 %d 条", count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .idle:
                    if !viewModel.messages.isEmpty {
                        Text(LF("已加载 %d 条", viewModel.messages.count))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(viewModel.hasMoreMessages ? L("向下滚动加载更早消息") : L("已加载全部本地消息"))
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .animation(.default, value: progress)
    }
}
