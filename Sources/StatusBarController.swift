import AppKit
import Combine

@MainActor
class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var statusMenuItem: NSMenuItem?
    private var pauseMenuItem: NSMenuItem?
    private var serversSubmenu: NSMenu?
    private var errorMenuItem: NSMenuItem?
    private var syncMenuItem: NSMenuItem?
    private var syncStatusMenuItem: NSMenuItem?
    private var aboutWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    var onReloadConfig: (() -> Void)?

    // Connection tracking
    private var serverStatuses: [String: ServerConnectionStatus] = [:]
    private var connectingAnimationTimer: Timer?
    private var connectingAnimationVisible: Bool = true
    private var currentConfigError: String?
    private var unreadCount: Int = 0

    enum ConnectionState {
        case connecting    // Never connected yet (orange, flashing)
        case connected     // Currently connected (green)
        case disconnected  // Was connected, now lost (red)
    }

    struct ServerConnectionStatus {
        let url: String
        let topics: [String]
        var isConnected: Bool
        var hasEverConnected: Bool  // Track if we've ever successfully connected
        var hasFailedAttempt: Bool = false  // Track if at least one attempt ended in failure

        var state: ConnectionState {
            if isConnected {
                return .connected
            } else if hasEverConnected || hasFailedAttempt {
                return .disconnected
            } else {
                return .connecting
            }
        }
    }

    static let shared = StatusBarController()

    private override init() {
        super.init()
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            // Use SF Symbol for menu bar icon
            if let image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "ntfy") {
                image.isTemplate = true // Makes it adapt to light/dark mode
                button.image = image
            }
            button.toolTip = "ntfyx"
        }

        setupMenu()
        observeSyncStatus()
    }

    private func setupMenu() {
        menu = NSMenu()
        menu?.autoenablesItems = false

        statusMenuItem = NSMenuItem(title: "连接中…", action: nil, keyEquivalent: "")
        statusMenuItem?.isEnabled = false
        menu?.addItem(statusMenuItem!)

        // Error menu item (hidden by default)
        errorMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        errorMenuItem?.isEnabled = false
        errorMenuItem?.isHidden = true
        menu?.addItem(errorMenuItem!)

        // Servers submenu showing individual server statuses
        let serversItem = NSMenuItem(title: "服务器", action: nil, keyEquivalent: "")
        serversSubmenu = NSMenu()
        serversItem.submenu = serversSubmenu
        menu?.addItem(serversItem)

        menu?.addItem(NSMenuItem.separator())

        let pauseItem = NSMenuItem(title: "暂停通知", action: #selector(togglePauseNotifications), keyEquivalent: "p")
        pauseItem.target = self
        pauseItem.state = NotificationPause.shared.isPaused ? .on : .off
        pauseItem.toolTip = "暂停横幅通知；消息仍会写入历史并计入未读"
        menu?.addItem(pauseItem)
        pauseMenuItem = pauseItem

        // ⇧⌘H / ⇧⌘L keep ⌘H (隐藏应用) and ⌘L free for the app's main menu
        let historyItem = NSMenuItem(title: "通知历史…", action: #selector(openHistory), keyEquivalent: "h")
        historyItem.keyEquivalentModifierMask = [.command, .shift]
        historyItem.target = self
        historyItem.isEnabled = true
        menu?.addItem(historyItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.isEnabled = true
        menu?.addItem(settingsItem)

        let showConfigItem = NSMenuItem(title: "在 Finder 中显示配置", action: #selector(showConfigInFinder), keyEquivalent: "")
        showConfigItem.target = self
        showConfigItem.isEnabled = true
        menu?.addItem(showConfigItem)

        let reloadConfigItem = NSMenuItem(title: "重载配置", action: #selector(reloadConfig), keyEquivalent: "r")
        reloadConfigItem.target = self
        reloadConfigItem.isEnabled = true
        menu?.addItem(reloadConfigItem)

        // iCloud sync (hidden until the feature is turned on)
        syncStatusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        syncStatusMenuItem?.isEnabled = false
        syncStatusMenuItem?.isHidden = true
        menu?.addItem(syncStatusMenuItem!)

        syncMenuItem = NSMenuItem(title: "立即同步配置", action: #selector(syncConfigNow), keyEquivalent: "")
        syncMenuItem?.target = self
        syncMenuItem?.isEnabled = true
        syncMenuItem?.isHidden = true
        syncMenuItem?.toolTip = "与 iCloud Drive 中的配置立即合并；平时由配置改动与定时轮询触发"
        menu?.addItem(syncMenuItem!)

        menu?.addItem(NSMenuItem.separator())

        let viewLogsItem = NSMenuItem(title: "查看日志…", action: #selector(viewLogs), keyEquivalent: "l")
        viewLogsItem.keyEquivalentModifierMask = [.command, .shift]
        viewLogsItem.target = self
        viewLogsItem.isEnabled = true
        menu?.addItem(viewLogsItem)

        menu?.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "关于 ntfyx", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        aboutItem.isEnabled = true
        menu?.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.isEnabled = true
        menu?.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc func openSettings() {
        SettingsWindowController.shared.showSettings()
    }

    @objc func openHistory() {
        HistoryWindowController.shared.showHistory()
    }

    @objc func showConfigInFinder() {
        let configPath = NSString(string: "~/.config/ntfyx").expandingTildeInPath
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: configPath)
    }

    @objc func reloadConfig() {
        onReloadConfig?()
    }

    @objc func togglePauseNotifications() {
        let paused = NotificationPause.shared.toggle()
        pauseMenuItem?.state = paused ? .on : .off
        Log.info(paused ? "通知横幅已暂停" : "通知横幅已恢复")
        refreshMainStatus()
    }

    @objc func viewLogs() {
        // All logs now go to the same location with rotation
        if FileManager.default.fileExists(atPath: Log.logFilePath) {
            NSWorkspace.shared.selectFile(Log.logFilePath, inFileViewerRootedAtPath: Log.logDirectory)
            return
        }

        // No logs found
        let alert = NSAlert()
        alert.messageText = "未找到日志"
        alert.informativeText = "尚未生成日志文件。日志将写入 \(Log.logDirectory)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
        AppMode.demoteToAccessoryIfNeeded()
    }

    @objc func openServerURL(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func showAbout() {
        // Reuse the window even after it has been closed: a fresh one per reopen would leak
        // both the old window and its close observer, which is registered once per window.
        if let existingWindow = aboutWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "关于 ntfyx"
        window.center()
        window.isReleasedWhenClosed = false  // Keep window object alive after closing

        let contentView = NSView(frame: window.contentView!.bounds)

        // Title
        let titleLabel = NSTextField(labelWithString: "ntfyx")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 18)
        titleLabel.frame = NSRect(x: 20, y: 155, width: 300, height: 25)
        contentView.addSubview(titleLabel)

        // Version
        let versionLabel = NSTextField(labelWithString: "版本 \(AppConstants.effectiveVersion)")
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.frame = NSRect(x: 20, y: 135, width: 300, height: 18)
        contentView.addSubview(versionLabel)

        // Description with clickable links
        let textView = NSTextView(frame: NSRect(x: 17, y: 45, width: 306, height: 85))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false

        let attributedString = NSMutableAttributedString()
        let normalAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor
        ]
        let linkAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        attributedString.append(NSAttributedString(string: "ntfy.sh 的原生 macOS 客户端\n\n", attributes: normalAttrs))
        attributedString.append(NSAttributedString(string: "作者：", attributes: normalAttrs))

        let authorLink = NSMutableAttributedString(string: "Laurent FRANCOISE", attributes: linkAttrs)
        authorLink.addAttribute(.link, value: "https://laurentftech.github.io", range: NSRange(location: 0, length: authorLink.length))
        attributedString.append(authorLink)

        attributedString.append(NSAttributedString(string: "\n", attributes: normalAttrs))

        let githubLink = NSMutableAttributedString(string: "ntfyx on GitHub", attributes: linkAttrs)
        githubLink.addAttribute(.link, value: "https://github.com/Felix2yu/ntfyx", range: NSRange(location: 0, length: githubLink.length))
        attributedString.append(githubLink)

        attributedString.append(NSAttributedString(string: "\n\n基于 ", attributes: normalAttrs))

        let ntfyLink = NSMutableAttributedString(string: "ntfy", attributes: linkAttrs)
        ntfyLink.addAttribute(.link, value: "https://ntfy.sh", range: NSRange(location: 0, length: ntfyLink.length))
        attributedString.append(ntfyLink)

        attributedString.append(NSAttributedString(string: " 构建，作者 Philipp C. Heckel", attributes: normalAttrs))

        textView.textStorage?.setAttributedString(attributedString)
        contentView.addSubview(textView)

        // License
        let licenseLabel = NSTextField(labelWithString: "基于 MIT 许可证开源")
        licenseLabel.font = NSFont.systemFont(ofSize: 11)
        licenseLabel.textColor = .tertiaryLabelColor
        licenseLabel.frame = NSRect(x: 20, y: 15, width: 300, height: 16)
        contentView.addSubview(licenseLabel)

        window.contentView = contentView
        aboutWindow = window  // Store reference to prevent deallocation
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Ensure a background service reverts to accessory mode when the About window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppMode.demoteToAccessoryIfNeeded()
            }
        }
    }

    func updateStatus(_ status: String) {
        statusMenuItem?.title = status
    }

    // MARK: - iCloud config sync

    @objc private func syncConfigNow() {
        ConfigSyncService.shared.syncNow()
    }

    private func observeSyncStatus() {
        refreshSyncMenuItems(ConfigSyncService.shared.status)
        ConfigSyncService.shared.statusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.refreshSyncMenuItems(status)
            }
            .store(in: &cancellables)
    }

    private func refreshSyncMenuItems(_ status: ConfigSyncService.Status) {
        let showSync = ConfigSyncService.shared.isEnabled
        syncMenuItem?.isHidden = !showSync
        guard let item = syncStatusMenuItem else { return }
        item.isHidden = !showSync
        guard showSync else { return }

        item.attributedTitle = nil
        item.toolTip = nil
        switch status {
        case .off:
            item.title = "iCloud 同步：已关闭"
        case .waiting:
            item.title = "iCloud 同步：等待首次同步"
        case .syncing:
            item.title = "iCloud 同步：正在同步…"
        case .synced(let date):
            item.title = "iCloud 同步：已于 \(SyncTimeFormat.string(date)) 同步"
        case .failed(let message):
            item.title = ""
            item.attributedTitle = NSAttributedString(
                string: "⚠️ iCloud 同步失败",
                attributes: [
                    .foregroundColor: NSColor.systemOrange,
                    .font: NSFont.systemFont(ofSize: 13)
                ]
            )
            item.toolTip = message
        }
    }

    /// Shows a configuration error in the menu (in red)
    func showConfigError(_ error: String) {
        currentConfigError = error
        errorMenuItem?.isHidden = false

        // Create attributed string with red color
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.systemFont(ofSize: 13)
        ]
        let attributedTitle = NSAttributedString(string: "⚠️ 配置错误", attributes: attributes)
        errorMenuItem?.attributedTitle = attributedTitle
        errorMenuItem?.toolTip = error
    }

    /// Shows a configuration warning in the menu (in orange)
    func showConfigWarning(_ warning: String) {
        currentConfigError = warning
        errorMenuItem?.isHidden = false

        // Create attributed string with orange color
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemOrange,
            .font: NSFont.systemFont(ofSize: 13)
        ]
        let attributedTitle = NSAttributedString(string: "⚠️ 配置警告", attributes: attributes)
        errorMenuItem?.attributedTitle = attributedTitle
        errorMenuItem?.toolTip = warning
    }

    /// Clears any config error/warning from the menu
    func clearConfigError() {
        currentConfigError = nil
        errorMenuItem?.isHidden = true
        errorMenuItem?.attributedTitle = nil
        errorMenuItem?.toolTip = nil
    }

    /// Initialize server tracking from config
    /// Applies a new server list while keeping the connection state of servers that
    /// stayed subscribed — used by the incremental config reload (audit 2.2), where
    /// untouched connections must not blink back to "connecting".
    func updateServers(servers: [(url: String, topics: [String])]) {
        stopConnectingAnimation()
        var updated: [String: ServerConnectionStatus] = [:]
        for server in servers {
            if let existing = serverStatuses[server.url] {
                updated[server.url] = ServerConnectionStatus(
                    url: existing.url, topics: server.topics,
                    isConnected: existing.isConnected,
                    hasEverConnected: existing.hasEverConnected,
                    hasFailedAttempt: existing.hasFailedAttempt
                )
            } else {
                updated[server.url] = ServerConnectionStatus(
                    url: server.url, topics: server.topics,
                    isConnected: false, hasEverConnected: false
                )
            }
        }
        serverStatuses = updated
        refreshServersSubmenu()
        refreshMainStatus()
        startConnectingAnimationIfNeeded()
    }

    /// Update connection status for a specific server
    func setServerConnected(_ serverUrl: String, connected: Bool) {        if var status = serverStatuses[serverUrl] {
            status.isConnected = connected
            if connected {
                status.hasEverConnected = true
            } else {
                status.hasFailedAttempt = true
            }
            serverStatuses[serverUrl] = status
            refreshServersSubmenu()
            refreshMainStatus()
            updateConnectingAnimation()
        }
    }

    /// Get all server connection statuses (for Settings view)
    func getServerStatuses() -> [String: ServerConnectionStatus] {
        return serverStatuses
    }

    // MARK: - Connecting Animation

    private func startConnectingAnimationIfNeeded() {
        let hasConnectingServers = serverStatuses.values.contains { $0.state == .connecting }
        if hasConnectingServers && connectingAnimationTimer == nil {
            connectingAnimationVisible = true
            connectingAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.toggleConnectingAnimation()
                }
            }
        }
    }

    private func stopConnectingAnimation() {
        connectingAnimationTimer?.invalidate()
        connectingAnimationTimer = nil
        connectingAnimationVisible = true
    }

    private func updateConnectingAnimation() {
        let hasConnectingServers = serverStatuses.values.contains { $0.state == .connecting }
        if hasConnectingServers {
            startConnectingAnimationIfNeeded()
        } else {
            stopConnectingAnimation()
        }
    }

    private func toggleConnectingAnimation() {
        connectingAnimationVisible.toggle()
        refreshMainStatus()
        refreshServersSubmenu()
    }

    private func updateMenuBarIcon(hasDisconnected: Bool) {
        // A pause outranks the connection state on the bell itself.
        let symbolName: String
        if NotificationPause.shared.isPaused {
            symbolName = "bell.slash.fill"
        } else {
            symbolName = hasDisconnected ? "bell" : "bell.fill"
        }
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ntfy") {
            image.isTemplate = true
            statusItem?.button?.image = image
        }
        // Show unread count next to the bell (from the history store)
        statusItem?.button?.title = unreadCount > 0 ? " \(unreadCount)" : ""
        statusItem?.length = NSStatusItem.variableLength
    }

    /// Updates the unread badge shown next to the menu bar icon.
    func setUnreadCount(_ count: Int) {
        guard count != unreadCount else { return }
        unreadCount = count
        refreshMainStatus()
    }

    private func refreshMainStatus() {
        let totalServers = serverStatuses.count
        let connectedServers = serverStatuses.values.filter { $0.state == .connected }.count
        let connectingServers = serverStatuses.values.filter { $0.state == .connecting }.count
        let disconnectedServers = serverStatuses.values.filter { $0.state == .disconnected }.count
        let totalTopics = serverStatuses.values.flatMap { $0.topics }.count

        updateMenuBarIcon(hasDisconnected: disconnectedServers > 0)

        let attributedTitle = NSMutableAttributedString()
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13)
        ]

        if totalServers == 0 {
            statusMenuItem?.attributedTitle = NSAttributedString(
                string: "未配置服务器",
                attributes: textAttrs
            )
        } else if connectedServers == totalServers {
            // Green indicator for all connected
            let statusAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.systemGreen,
                .font: NSFont.systemFont(ofSize: 13)
            ]
            attributedTitle.append(NSAttributedString(string: "● ", attributes: statusAttrs))

            attributedTitle.append(NSAttributedString(
                string: "\(totalServers) 台服务器 · \(totalTopics) 个主题",
                attributes: textAttrs
            ))
            statusMenuItem?.attributedTitle = attributedTitle
        } else if connectingServers > 0 && disconnectedServers == 0 && connectedServers == 0 {
            // All servers are still connecting (flashing orange)
            let statusAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: connectingAnimationVisible ? NSColor.systemOrange : NSColor.clear,
                .font: NSFont.systemFont(ofSize: 13)
            ]
            attributedTitle.append(NSAttributedString(string: "● ", attributes: statusAttrs))
            attributedTitle.append(NSAttributedString(string: "连接中…", attributes: textAttrs))
            statusMenuItem?.attributedTitle = attributedTitle
        } else if disconnectedServers > 0 {
            // Some servers disconnected (red indicator)
            let statusAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.systemFont(ofSize: 13)
            ]
            attributedTitle.append(NSAttributedString(string: "● ", attributes: statusAttrs))
            attributedTitle.append(NSAttributedString(
                string: "已连接 \(connectedServers)/\(totalServers) 台服务器",
                attributes: textAttrs
            ))
            statusMenuItem?.attributedTitle = attributedTitle
        } else {
            // Mixed state: some connected, some connecting (orange)
            let statusAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: connectingAnimationVisible ? NSColor.systemOrange : NSColor.clear,
                .font: NSFont.systemFont(ofSize: 13)
            ]
            attributedTitle.append(NSAttributedString(string: "● ", attributes: statusAttrs))
            attributedTitle.append(NSAttributedString(
                string: "已连接 \(connectedServers)/\(totalServers) 台服务器",
                attributes: textAttrs
            ))
            statusMenuItem?.attributedTitle = attributedTitle
        }

        // A pause must be visible without opening the menu.
        if NotificationPause.shared.isPaused, let item = statusMenuItem, let current = item.attributedTitle {
            let combined = NSMutableAttributedString(attributedString: current)
            combined.append(NSAttributedString(
                string: " · 通知已暂停",
                attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 13)
                ]
            ))
            item.attributedTitle = combined
        }
    }

    private func refreshServersSubmenu() {
        serversSubmenu?.removeAllItems()

        if serverStatuses.isEmpty {
            let noServersItem = NSMenuItem(title: "未配置服务器", action: nil, keyEquivalent: "")
            noServersItem.isEnabled = false
            serversSubmenu?.addItem(noServersItem)
            return
        }

        for (_, status) in serverStatuses.sorted(by: { $0.key < $1.key }) {
            let topicsText = status.topics.joined(separator: ", ")

            // Create attributed string with colored status indicator
            let serverItem = NSMenuItem(title: "", action: #selector(openServerURL(_:)), keyEquivalent: "")
            serverItem.target = self
            serverItem.representedObject = status.url

            let attributedTitle = NSMutableAttributedString()

            // Status indicator with color based on connection state
            let statusIcon: String
            let statusColor: NSColor

            switch status.state {
            case .connected:
                statusIcon = "●"
                statusColor = NSColor.systemGreen
            case .disconnected:
                statusIcon = "●"
                statusColor = NSColor.systemRed
            case .connecting:
                statusIcon = "●"
                // Flashing effect for connecting
                statusColor = connectingAnimationVisible ? NSColor.systemOrange : NSColor.clear
            }

            let statusAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: statusColor,
                .font: NSFont.systemFont(ofSize: 13)
            ]
            attributedTitle.append(NSAttributedString(string: "\(statusIcon) ", attributes: statusAttrs))

            // Server URL in normal color
            let urlAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 13)
            ]
            attributedTitle.append(NSAttributedString(string: status.url, attributes: urlAttrs))

            serverItem.attributedTitle = attributedTitle

            // Add tooltip with topics and state
            let stateText: String
            switch status.state {
            case .connected: stateText = "已连接"
            case .disconnected: stateText = "已断开"
            case .connecting: stateText = "连接中…"
            }
            serverItem.toolTip = "\(stateText)\n主题：\(topicsText)"

            serversSubmenu?.addItem(serverItem)

            // Add topics as indented subitems
            for topic in status.topics {
                let topicItem = NSMenuItem(title: "    \(topic)", action: nil, keyEquivalent: "")
                topicItem.isEnabled = false
                topicItem.indentationLevel = 1
                serversSubmenu?.addItem(topicItem)
            }
        }
    }
}
