import SwiftUI
import AppKit
import NtfyxCore

// MARK: - Menu content

/// Contents of the menu bar menu (`.menu` style), driven entirely by observable state
/// in `ConnectionRegistry` / `ConfigSyncService` / `NotificationPause`.
struct MenuBarMenuView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    private var table: ConnectionRegistry { env.connections }
    private var sync: ConfigSyncService { env.configSync }

    var body: some View {
        statusRow

        if let issue = table.configIssue {
            issueRow(issue)
        }

        serversMenu

        Divider()

        Toggle("暂停通知", isOn: pauseBinding)
            .help("暂停横幅通知；消息仍会写入历史并计入未读")
            .keyboardShortcut("p", modifiers: .command)

        // ⇧⌘H keeps ⌘H (隐藏应用) free for the app's main menu.
        Button("通知历史…") {
            openWindow(id: "history")
        }
        .keyboardShortcut("h", modifiers: [.command, .shift])

        Button("设置…") {
            AppEnvironment.openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("在 Finder 中显示配置") {
            AppActions.showConfigInFinder()
        }

        Button("重载配置") {
            env.reloadConfig()
        }
        .keyboardShortcut("r", modifiers: .command)

        if sync.isEnabled {
            syncStatusRow
            Button("立即同步配置") {
                sync.syncNow()
            }
            .help("与 iCloud Drive 中的配置立即合并；平时由配置改动与定时轮询触发")
        }

        Divider()

        Button("查看日志…") {
            AppActions.viewLogs()
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])

        Divider()

        Button("关于 ntfyx") {
            openWindow(id: "about")
        }

        Button("退出 ntfyx") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Rows

    private var statusRow: some View {
        let line = table.statusLine
        let paused = NotificationPause.shared.isPaused
        return Button(action: {}) {
            HStack(spacing: 6) {
                statusDot(line.dot)
                Text(line.text)
                if paused {
                    Text(" · 通知已暂停")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .disabled(true)
    }

    private func issueRow(_ issue: ConnectionRegistry.ConfigIssue) -> some View {
        let isError: Bool
        let title: String
        let message: String
        switch issue {
        case .warning(let text):
            isError = false; title = "⚠️ 配置警告"; message = text
        case .error(let text):
            isError = true; title = "⚠️ 配置错误"; message = text
        }
        return Button(action: {}) {
            HStack(spacing: 6) {
                Text(title)
                    .foregroundStyle(isError ? Color(nsColor: .systemRed) : Color(nsColor: .systemOrange))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .disabled(true)
        .help(message)
    }

    @ViewBuilder
    private func statusDot(_ dot: ConnectionRegistry.StatusLine.Dot) -> some View {
        switch dot {
        case .none:
            EmptyView()
        case .green:
            Text("●").foregroundStyle(Color(nsColor: .systemGreen))
        case .red:
            Text("●").foregroundStyle(Color(nsColor: .systemRed))
        case .orangePulse:
            Text("●")
                .foregroundStyle(Color(nsColor: .systemOrange))
                .opacity(table.pulseVisible ? 1 : 0)
        }
    }

    @ViewBuilder
    private func statusDot(_ state: ConnectionRegistry.ConnectionState) -> some View {
        switch state {
        case .connected:
            Text("●").foregroundStyle(Color(nsColor: .systemGreen))
        case .disconnected:
            Text("●").foregroundStyle(Color(nsColor: .systemRed))
        case .connecting:
            Text("●")
                .foregroundStyle(Color(nsColor: .systemOrange))
                .opacity(table.pulseVisible ? 1 : 0)
        }
    }

    private var serversMenu: some View {
        Menu("服务器") {
            if table.sortedStatuses.isEmpty {
                Text("未配置服务器")
            } else {
                ForEach(table.sortedStatuses, id: \.url) { status in
                    Menu {
                        Button(status.url) {
                            if let url = URL(string: status.url) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        ForEach(status.topics, id: \.self) { topic in
                            Text("    \(topic)")
                        }
                    } label: {
                        HStack(spacing: 6) {
                            statusDot(status.state)
                            Text(status.url)
                            Spacer(minLength: 0)
                        }
                    }
                    .help({
                        switch status.state {
                        case .connected: return "已连接\n主题：\(status.topics.joined(separator: ", "))"
                        case .disconnected: return "已断开\n主题：\(status.topics.joined(separator: ", "))"
                        case .connecting: return "连接中…\n主题：\(status.topics.joined(separator: ", "))"
                        }
                    }())
                }
            }
        }
    }

    private var syncStatusRow: some View {
        Button(action: {}) {
            HStack(spacing: 0) {
                switch sync.status {
                case .off:
                    Text("iCloud 同步：已关闭")
                case .waiting:
                    Text("iCloud 同步：等待首次同步")
                case .syncing:
                    Text("iCloud 同步：正在同步…")
                case .synced(let date):
                    Text("iCloud 同步：已于 \(SyncTimeFormat.string(date)) 同步")
                case .failed(let message):
                    Text("⚠️ iCloud 同步失败")
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .help(message)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .disabled(true)
    }

    private var pauseBinding: Binding<Bool> {
        Binding(
            get: { NotificationPause.shared.isPaused },
            set: { newValue in
                if newValue != NotificationPause.shared.isPaused {
                    _ = NotificationPause.shared.toggle()
                }
            }
        )
    }
}

// MARK: - Status item label

/// The bell (plus unread count) shown in the menu bar itself.
///
/// This view is alive for the whole process lifetime, so it also owns the bridge that
/// turns `WindowRouter` requests into `openWindow(id:)` calls.
struct MenuBarLabel: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    private var table: ConnectionRegistry { env.connections }
    private var router: WindowRouter { env.router }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: iconName)
            if table.unreadCount > 0 {
                Text(" \(table.unreadCount)")
            }
        }
        .onAppear(perform: routePending)
        .onChange(of: router.token) { _, _ in
            routePending()
        }
    }

    private var iconName: String {
        if NotificationPause.shared.isPaused {
            return "bell.slash.fill"
        }
        return table.hasDisconnectedServers ? "bell" : "bell.fill"
    }

    private func routePending() {
        guard let route = router.dequeue() else { return }
        switch route {
        case .history(let topic):
            openWindow(id: "history")
            if let topic {
                env.makeHistoryViewModel()?.selectTopic(named: topic)
            }
        case .settings:
            AppEnvironment.openSettings()
        case .about:
            openWindow(id: "about")
        case .permission:
            openWindow(id: "permission")
        }
    }
}
