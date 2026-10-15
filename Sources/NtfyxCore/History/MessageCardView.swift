import SwiftUI

/// A single notification card in the history list, mirroring ntfy web's NotificationCard:
/// priority icon + emoji-tagged title + time, body, actions row, attachment row, click link,
/// and hover operations (read toggle / copy / delete).
struct MessageCardView: View {
    let stored: StoredMessage
    let attachmentState: HistoryViewModel.AttachmentState?
    /// The topic's configured 备注; nil when the caller has none, so the id shows.
    var topicLabel: String?
    let onToggleRead: () -> Void
    let onDelete: () -> Void
    let onCopy: () -> Void
    let onOpenURL: (String) -> Void
    let onAction: (NtfyMessage.NtfyAction) -> Void
    let onDownloadAttachment: () -> Void
    /// Labels the topic in the merged per-server list; a single topic's list needs no label.
    var showsTopic: Bool = false

    @State private var isHovered = false
    /// nil = follow the 默认展开 setting; set once the user toggles this card.
    @State private var expansionOverride: Bool?
    @AppStorage(AppSettings.expandMessagesByDefaultKey) private var expandByDefault = false
    @AppStorage(AppSettings.messageFontSizeKey) private var messageFontSize = 13.0

    private var expanded: Bool { expansionOverride ?? expandByDefault }

    private var message: NtfyMessage { stored.message }

    /// `fullTitle` already falls back to the topic name, so a titleless message would
    /// otherwise wear the same word twice.
    private var showsTopicChip: Bool {
        guard showsTopic else { return false }
        let title = message.plainTextTitle ?? message.title ?? ""
        return !title.isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Unread indicator
            Circle()
                .fill(stored.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 6) {
                headerRow
                bodyText
                clickRow
                attachmentRow
                actionsRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { markReadIfNeeded() }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(stored.isRead ? Color.primary.opacity(0.03) : Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(stored.isRead ? 0.06 : 0.12), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            hoverButtons
                .padding(.trailing, 6)
                .padding(.top, 4)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .onHover { isHovered = $0 }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            if let priorityIcon = priorityIcon {
                Image(systemName: priorityIcon.symbol)
                    .foregroundStyle(priorityIcon.color)
            }

            if showsTopicChip {
                Text(displayedTopic)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }

            Text(fullTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(MessageActionService.formattedTime(message.time))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
        // Reserve room for the hover pill so the timestamp is never covered by it.
        .padding(.trailing, isHovered ? 80 : 0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }

    private var fullTitle: String {
        let emoji = EmojiTags.emojiPrefix(for: message.tags)
        let title = message.plainTextTitle ?? message.title
        if let title, !title.isEmpty {
            return emoji + title
        }
        return emoji + displayedTopic
    }

    /// The topic the way the user named it, or its id when no 备注 is configured.
    private var displayedTopic: String { topicLabel ?? message.topic }

    private var hoverButtons: some View {
        HStack(spacing: 2) {
            cardButton(
                symbol: stored.isRead ? "envelope.open" : "envelope.badge",
                help: stored.isRead ? "标为未读" : "标为已读",
                action: onToggleRead
            )
            cardButton(symbol: "doc.on.doc", help: "复制消息内容", action: onCopy)
            cardButton(symbol: "trash", help: "删除这条消息", action: onDelete)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private func cardButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: - Body

    @ViewBuilder
    private var bodyText: some View {
        if let body = bodyString, !body.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if message.isMarkdown {
                    // Rich rendering for the history list; banners still get plain text.
                    Text(MarkdownRenderer.render(body, fontSize: CGFloat(messageFontSize)))
                        .lineLimit(expanded ? nil : 6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .onTapGesture { bodyTapped() }
                } else {
                    Text(body)
                        .font(.system(size: messageFontSize))
                        .foregroundStyle(.primary)
                        .lineLimit(expanded ? nil : 6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .onTapGesture { bodyTapped() }
                }
                if isExpandable {
                    Button {
                        toggleExpanded()
                    } label: {
                        Label(expanded ? "收起" : "展开全文",
                              systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Markdown messages render from the raw source; everything else keeps the
    /// markdown-stripped plain text for consistency with banners.
    private var bodyString: String? {
        if message.isMarkdown { return message.message }
        return message.plainTextMessage ?? message.message
    }

    /// Long bodies are clipped to 6 lines; heuristic on raw line count and length
    /// decides whether the expand affordance is shown.
    private var isExpandable: Bool {
        guard let body = bodyString else { return false }
        return body.split(separator: "\n", omittingEmptySubsequences: false).count > 6 || body.count > 320
    }

    private func toggleExpanded() {
        withAnimation(.easeOut(duration: 0.15)) {
            expansionOverride = !expanded
        }
    }

    private func bodyTapped() {
        markReadIfNeeded()
        if isExpandable { toggleExpanded() }
    }

    /// Card-level tap marks an unread message as read; `onToggleRead` is a toggle,
    /// so it must only fire when unread.
    private func markReadIfNeeded() {
        if !stored.isRead { onToggleRead() }
    }

    // MARK: - Click URL

    @ViewBuilder
    private var clickRow: some View {
        if let click = message.click, !click.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "link")
                    .font(.caption)
                Text(click)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.link)
            .contentShape(Rectangle())
            .onTapGesture { onOpenURL(click) }
            .help("打开链接")
        }
    }

    // MARK: - Attachment

    @ViewBuilder
    private var attachmentRow: some View {
        if let attachment = message.attachment {
            let isFailed = {
                if case .failed = attachmentState { return true }
                return false
            }()
            Button(action: onDownloadAttachment) {
                HStack(spacing: 6) {
                    Image(systemName: isFailed ? "exclamationmark.arrow.circlepath" : "paperclip")
                        .foregroundStyle(isFailed ? Color.red : Color.secondary)
                    Text(attachment.name)
                        .font(.callout)
                        .lineLimit(1)
                    if let size = attachment.size {
                        Text(MessageActionService.formattedFileSize(size))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    switch attachmentState {
                    case .downloading:
                        ProgressView()
                            .controlSize(.small)
                    case .failed(let reason):
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    case nil:
                        EmptyView()
                    }
                }
                .foregroundStyle(.link)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(attachmentState == .downloading)
            .help("下载并在默认应用中预览附件")
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsRow: some View {
        if let actions = message.actions, !actions.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Button {
                        onAction(action)
                    } label: {
                        Label(action.label, systemImage: symbolForAction(action))
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(helpForAction(action))
                }
            }
        }
    }

    private func symbolForAction(_ action: NtfyMessage.NtfyAction) -> String {
        switch action.action {
        case "view": return "safari"
        case "http": return "network"
        case "copy": return "doc.on.doc"
        default: return "rectangle.portrait.on.rectangle.portrait"
        }
    }

    private func helpForAction(_ action: NtfyMessage.NtfyAction) -> String {
        switch action.action {
        case "view": return "打开 \(action.url ?? "")"
        case "http": return "发送 \(action.method ?? "POST") 请求"
        case "copy": return "复制到剪贴板"
        default: return action.action
        }
    }

    // MARK: - Priority

    private var priorityIcon: (symbol: String, color: Color)? {
        switch message.priority {
        case 5: return ("exclamationmark.triangle.fill", .red)
        case 4: return ("exclamationmark.circle.fill", .orange)
        case 2: return ("arrow.down.circle", .teal)
        case 1: return ("arrow.down.to.line", .secondary)
        default: return nil  // priority 3 / nil: no icon, like ntfy web
        }
    }
}
