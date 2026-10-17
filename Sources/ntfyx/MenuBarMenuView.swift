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

        Toggle(L("暂停通知"), isOn: pauseBinding)
            .help(L("暂停横幅通知；消息仍会写入历史并计入未读"))
            .keyboardShortcut("p", modifiers: .command)

        // ⇧⌘H keeps ⌘H (隐藏应用) free for the app's main menu.
        Button(L("消息记录…")) {
            openWindow(id: "history")
        }
        .keyboardShortcut("h", modifiers: [.command, .shift])

        Button(L("设置…")) {
            AppEnvironment.openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button(L("在 Finder 中显示配置")) {
            AppActions.showConfigInFinder()
        }

        Button(L("重载配置")) {
            env.reloadConfig()
        }
        .keyboardShortcut("r", modifiers: .command)

        if sync.isEnabled {
            syncStatusRow
            Button(L("立即同步配置")) {
                sync.syncNow()
            }
            .help(L("与 iCloud Drive 中的配置立即合并；平时由配置改动与云端变更事件触发"))
        }

        Divider()

        Button(L("查看日志…")) {
            AppActions.viewLogs()
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])

        Divider()

        Button(L("关于 ntfyx")) {
            openWindow(id: "about")
        }

        Button(L("退出 ntfyx")) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Rows

    private var statusRow: some View {
        let line = table.statusLine
        let paused = NotificationPause.shared.isPaused
        return Text(dotted(dotColor(line.dot), paused ? "\(line.text) · \(L("通知已暂停"))" : line.text))
    }

    private func issueRow(_ issue: ConnectionRegistry.ConfigIssue) -> some View {
        let title: String
        let message: String
        let color: Color
        switch issue {
        case .warning(let text):
            title = L("⚠️ 配置警告"); message = text; color = Color(nsColor: .systemOrange)
        case .error(let text):
            title = L("⚠️ 配置错误"); message = text; color = Color(nsColor: .systemRed)
        }
        return Text(tinted(title, color))
            .help(message)
    }

    /// `MenuBarExtra(.menu)` converts labels into `NSMenuItem`s and an `HStack` label
    /// collapses to its first child, so a row's text has to live in one attributed `Text`.
    private func dotted(_ dot: Color?, _ text: String) -> AttributedString {
        guard let dot else { return AttributedString(text) }
        return tinted("● ", dot) + AttributedString(text)
    }

    private func tinted(_ text: String, _ color: Color) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = color
        return attributed
    }

    private func dotColor(_ dot: ConnectionRegistry.StatusLine.Dot) -> Color? {
        switch dot {
        case .none: nil
        case .green: Color(nsColor: .systemGreen)
        case .red: Color(nsColor: .systemRed)
        case .orangePulse: pulseColor
        }
    }

    private func dotColor(_ state: ConnectionRegistry.ConnectionState) -> Color {
        switch state {
        case .connected: Color(nsColor: .systemGreen)
        case .disconnected: Color(nsColor: .systemRed)
        case .connecting: pulseColor ?? Color.clear
        }
    }

    /// The connecting dot blinks; while it is hidden the row keeps its indent with a clear run.
    private var pulseColor: Color? {
        table.pulseVisible ? Color(nsColor: .systemOrange) : .clear
    }

    private func stateText(_ state: ConnectionRegistry.ConnectionState) -> String {
        switch state {
        case .connected: L("已连接")
        case .disconnected: L("已断开")
        case .connecting: L("连接中…")
        }
    }

    private var serversMenu: some View {
        Menu(L("服务器")) {
            if table.sortedStatuses.isEmpty {
                Text(L("未配置服务器"))
            } else {
                ForEach(table.sortedStatuses, id: \.url) { status in
                    Button {
                        if let url = URL(string: status.url) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Text(dotted(dotColor(status.state), status.url))
                    }
                    .help(LF("%1$@\n主题：%2$@", stateText(status.state), status.topics.map(\.label).joined(separator: ", ")))

                    ForEach(status.topics, id: \.id) { topic in
                        Text("    \(topic.label)")
                            .help(Text(topic.idTooltip))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var syncStatusRow: some View {
        switch sync.status {
        case .off:
            Text(L("iCloud 同步：已关闭"))
        case .waiting:
            Text(L("iCloud 同步：等待首次同步"))
        case .syncing:
            Text(L("iCloud 同步：正在同步…"))
        case .synced(let date):
            Text(LF("iCloud 同步：%@", SyncTimeFormat.compactString(date)))
                .help(LF("上次同步：%@", SyncTimeFormat.string(date)))
        case .failed(let message):
            Text(tinted(L("⚠️ iCloud 同步失败"), Color(nsColor: .systemOrange)))
                .help(message)
        }
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
