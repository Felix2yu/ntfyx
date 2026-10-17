import SwiftUI
import AppKit

/// Single-page grouped settings form: 通用 / ntfy 服务器 / 本地通知服务,
/// servers rendered as collapsible rows so one or two servers stay compact.
struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    let syncService: ConfigSyncService
    @State private var copiedCommand: String?
    @State private var syncDirectory = ""

    @AppStorage(AppSettings.expandMessagesByDefaultKey) private var expandByDefault = false
    @AppStorage(AppSettings.scrollMarksReadKey) private var scrollMarksRead = false
    @AppStorage(AppSettings.messageFontSizeKey) private var messageFontSize = 13.0
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @Bindable private var locale = AppLocale.shared

    private var isLocalServerEnabled: Bool {
        !viewModel.localServerPort.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            generalSection
            serversSection
            iCloudSyncSection
            localServerSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 460, idealHeight: 600)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            syncDirectory = syncService.syncDirectory
        }
    }

    // MARK: - 通用

    private var generalSection: some View {
        Section {
            Picker(L("界面语言"), selection: $locale.choice) {
                Text(L("跟随系统")).tag(LanguageChoice.auto)
                Text("简体中文").tag(LanguageChoice.zhHans)
                Text("English").tag(LanguageChoice.en)
            }
            .help(L("只切换 ntfyx 的界面文字，保存在本机、不参与 iCloud 同步；服务器发来的消息保持原文。主菜单和个别窗口标题要重启 ntfyx 才跟着换"))

            Toggle(L("开机时启动"), isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    if let error = LoginItem.setEnabled(newValue) {
                        loginError = error
                        return
                    }
                    loginError = nil
                    launchAtLogin = newValue
                }
            ))
            .help(L("登录后自动在菜单栏运行 ntfyx"))

            if let loginError {
                Text(loginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Toggle(L("默认展开消息全文"), isOn: $expandByDefault)
                .help(L("长消息进入消息记录时即完整显示；单条仍可点击「收起」折回"))

            Toggle(L("滚动即已读"), isOn: $scrollMarksRead)
                .help(L("浏览历史时，滚动一停下就判定：某条消息的顶部越过窗口上沿四分之一行高，它连同上面的所有条目一起标为已读，并像点击卡片那样同步到服务器。只露头一角的不算，刚打开主题看到的那一屏也不算。窗口开着时新到的消息同样保持未读、横幅照常弹。已读条目仍留在列表里，不抽走、不跳位"))

            LabeledContent(L("消息字号")) {
                HStack(spacing: 8) {
                    Slider(value: $messageFontSize, in: 11...20, step: 1)
                        .frame(width: 160)
                    Text("\(Int(messageFontSize)) pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .help(L("消息记录里正文的字体大小，Markdown 标题随字号等比缩放"))
        } header: {
            Text(L("通用"))
        }
    }

    // MARK: - 服务器

    private var serversSection: some View {
        Section {
            ForEach($viewModel.servers) { $server in
                ServerRowView(server: $server, viewModel: viewModel)
            }

            Button {
                viewModel.addServer()
            } label: {
                Label(L("添加服务器"), systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            HStack {
                Text(L("ntfy 服务器"))
                if viewModel.hasUnsavedChanges {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                        .help(L("有未保存的更改"))
                }
            }
        }
    }

    // MARK: - iCloud 同步

    private var iCloudSyncSection: some View {
        Section {
            Toggle(L("通过 iCloud 同步配置"), isOn: Binding(
                get: { syncService.isEnabled },
                set: { syncService.setEnabled($0) }
            ))
            .help(L("在各台 Mac 之间同步服务器与主题配置。消息不经 iCloud，仍直接从 ntfy 服务器获取。"))

            if syncService.isEnabled {
                LabeledContent(L("同步文件夹")) {
                    HStack(spacing: 8) {
                        Text(syncDirectory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 250, alignment: .trailing)
                        Button(L("选择…")) { chooseSyncDirectory() }
                    }
                }

                if !syncService.directoryOverride.isEmpty {
                    Button(L("改用 iCloud Drive")) {
                        syncService.setDirectory("")
                        syncDirectory = syncService.syncDirectory
                    }
                    .buttonStyle(.borderless)
                }

                syncStatusRow

                Button {
                    syncService.syncNow()
                } label: {
                    Label(L("立即同步"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)

                Text(L("同步文件不包含服务器令牌：每台 Mac 的令牌只存在各自的钥匙串里，新加入同步的 Mac 需自行粘贴一次。脚本、图标路径、通知动作和本地服务端口也只留在本机，不参与同步。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L("iCloud 同步"))
        }
    }

    @ViewBuilder
    private var syncStatusRow: some View {
        switch syncService.status {
        case .off:
            EmptyView()
        case .waiting:
            Label(L("等待首次同步…"), systemImage: "icloud.and.arrow.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .syncing:
            Label(L("正在同步…"), systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .synced(let date):
            Label(LF("上次同步：%@", SyncTimeFormat.string(date)), systemImage: "checkmark.icloud.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func chooseSyncDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("选择")
        panel.message = L("选择存放 ntfyx 同步配置文件的文件夹")
        panel.directoryURL = URL(fileURLWithPath: syncService.syncDirectory, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        syncService.setDirectory(url.path)
        syncDirectory = syncService.syncDirectory
    }

    // MARK: - 本地通知服务

    private var localServerSection: some View {
        Section {
            HStack {
                Text(L("端口"))
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("", text: $viewModel.localServerPort)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L("端口"))
                    .frame(width: 100)
                    .multilineTextAlignment(.trailing)
            }

            Text(L("端口范围须为 1024–65535；留空表示禁用本地通知服务。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if isLocalServerEnabled {
                commandRow(
                    label: "curl",
                    command: "TOKEN=$(cat \"$HOME/Library/Application Support/ntfyx/local-token\"); curl -X POST http://127.0.0.1:\(viewModel.localServerPort)/notify -H \"Authorization: Bearer $TOKEN\" -H \"Content-Type: application/json\" -d '{\"title\": \"Hello\", \"message\": \"Hello from ntfyx!\"}'"
                )
            }
        } header: {
            Text(L("本地通知服务"))
        }
    }

    private func commandRow(label: String, command: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )

            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copiedCommand = command

                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if copiedCommand == command {
                        copiedCommand = nil
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copiedCommand == command ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.caption)
                    Text(copiedCommand == command ? L("已拷贝") : L("拷贝"))
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(copiedCommand == command ? .green : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(copiedCommand == command ? Color.green.opacity(0.2) : Color.accentColor)
                )
            }
            .buttonStyle(.plain)
            .help(L("拷贝到剪贴板"))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.blue.opacity(0.08),
                            Color.cyan.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: ConfigStore.defaultConfigPath))
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.borderless)
                .help(L("在编辑器中打开配置文件"))

                if let error = viewModel.saveError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button(L("取消")) {
                    viewModel.cancel()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button(L("保存")) {
                    viewModel.save()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!viewModel.hasUnsavedChanges)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .background(.bar)
    }

}

// MARK: - Server row (collapsible)

private struct ServerRowView: View {
    @Binding var server: EditableServer
    let viewModel: SettingsViewModel
    @State private var showTokenSheet = false
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 10) {
                HStack {
                    Text("URL")
                        .foregroundStyle(.secondary)
                    TextField("", text: $server.url)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("URL")
                }

                HStack {
                    if server.token.isEmpty {
                        Text(L("令牌：未配置"))
                            .foregroundStyle(.secondary)
                    } else if server.storeInKeychain {
                        Label(L("令牌存储于钥匙串"), systemImage: "key.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Label(L("令牌存储于配置文件"), systemImage: "doc.text")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(L("管理…")) {
                        showTokenSheet = true
                    }
                }

                Toggle(L("重连时拉取错过的消息"), isOn: $server.fetchMissed)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        viewModel.testConnection(for: server)
                    } label: {
                        Label(L("测试连接"), systemImage: "bolt.horizontal.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(server.url.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(L("按当前填写的地址与令牌探测服务器（无需先保存）"))

                    testResultView(viewModel.serverTestStates[server.id])
                    Spacer()
                }

                restrictionRow(
                    title: L("允许跳转方案"),
                    offLabel: L("默认 (http/https)"),
                    placeholder: "http, https, myapp",
                    help: L("限制该服务器消息可打开的 URL 方案；自定义列表留空等于全部禁止"),
                    mode: $server.schemesMode,
                    input: $server.schemesInput
                )

                restrictionRow(
                    title: L("信任域名"),
                    offLabel: L("不限制"),
                    placeholder: "*.example.com, ntfy.sh",
                    help: L("白名单：仅所列域名的链接可直接打开；*. 前缀匹配其子域；自定义列表留空等于全部禁止"),
                    mode: $server.domainsMode,
                    input: $server.domainsInput
                )

                Divider()

                ForEach($server.topics) { $topic in
                    TopicRowView(
                        topic: $topic,
                        onDelete: { server.topics.removeAll { $0.id == topic.id } },
                        testState: viewModel.topicTestStates[topic.id],
                        onSendTest: { viewModel.sendTestNotification(in: server, topic: topic) }
                    )
                }

                HStack {
                    Button {
                        viewModel.addTopic(to: server.id)
                    } label: {
                        Label(L("添加主题"), systemImage: "plus")
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button(role: .destructive) {
                        viewModel.removeServer(server)
                    } label: {
                        Text(L("删除此服务器"))
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(connectionColor(for: server.url))
                    .frame(width: 8, height: 8)
                Text(server.url.isEmpty ? L("新服务器") : server.url)
                    .fontWeight(.medium)
                Spacer()
                Text(LF("%d 个主题", server.topics.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .sheet(isPresented: $showTokenSheet) {
            TokenSheetView(server: $server)
        }
    }

    /// One 允许跳转方案 / 信任域名 row: mode popup plus, in custom mode, the list input.
    private func restrictionRow(
        title: String,
        offLabel: String,
        placeholder: String,
        help: String,
        mode: Binding<URLRestriction>,
        input: Binding<String>
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            Picker("", selection: mode) {
                Text(offLabel).tag(URLRestriction.off)
                Text(L("自定义列表")).tag(URLRestriction.custom)
                Text(L("全部禁止")).tag(URLRestriction.denyAll)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            if mode.wrappedValue == .custom {
                TextField(placeholder, text: input)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260)
            }

            Spacer(minLength: 0)
        }
        .help(help)
    }

    @ViewBuilder
    private func testResultView(_ state: SettingsViewModel.ServerTestState?) -> some View {        switch state {
        case .testing:
            ProgressView().controlSize(.small)
        case .reachable(let version):
            Label(
                version.map { LF("连接正常 · v%@", $0) } ?? L("连接正常"),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.caption)
        case .tokenRejected:
            Label(L("令牌被服务器拒绝"), systemImage: "key.slash")
                .foregroundStyle(.red)
                .font(.caption)
        case .failed(let reason):
            Label(LF("连接失败：%@", reason), systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(1)
        case .none:
            EmptyView()
        }
    }

    private func connectionColor(for url: String) -> Color {
        guard !url.isEmpty, let state = viewModel.connections.statuses[url]?.state else { return .gray }
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        }
    }
}
