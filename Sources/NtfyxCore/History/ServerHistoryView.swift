import SwiftUI

/// Message list merging every topic the local history holds for one server, newest first.
///
/// Narrower than TopicDetailView on purpose: loading full history and clearing are per-topic
/// operations, so they stay in the topic view while this list handles browsing across topics.
struct ServerHistoryView: View {
    @Bindable var viewModel: HistoryViewModel
    let serverURL: String

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            messageList

            Divider()

            footer
        }
        .frame(minWidth: 560)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("全部主题")
                    .font(.headline)
                Text(serverURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                viewModel.markServerAllRead(serverURL: serverURL)
            } label: {
                Label("全部已读", systemImage: "checkmark.circle")
            }
            .disabled(viewModel.unread(forServer: serverURL) == 0)
            .help("把该服务器所有主题的消息标为已读")

            Toggle(isOn: $viewModel.onlyUnread) {
                Text("仅看未读")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)

            TextField("搜索标题或正文", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
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
                                topicLabel: viewModel.label(for: stored.topicRef),
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
                                },
                                showsTopic: true
                            )
                            .id(stored.id)
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
            Text("该服务器暂无本地消息")
                .foregroundStyle(.secondary)
            Text("订阅主题后新收到的通知会自动保存在这里；单个主题还可以在其详情页「加载全部历史」。")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
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
                .help("关闭提示")
            } else if !viewModel.hasMoreMessages && !viewModel.messages.isEmpty {
                Text("已加载全部本地消息")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
