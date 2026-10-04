import SwiftUI
import AppKit

/// Single-page grouped settings form: 通用 / ntfy 服务器 / 本地通知服务,
/// servers rendered as collapsible rows so one or two servers stay compact.
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var syncService: ConfigSyncService
    @State private var copiedCommand: String?
    @State private var statusTimer: Timer?
    @State private var syncDirectory = ""

    @AppStorage(AppSettings.expandMessagesByDefaultKey) private var expandByDefault = false
    @AppStorage(AppSettings.messageFontSizeKey) private var messageFontSize = 13.0
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

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
            viewModel.refreshConnectionStates()
            startStatusTimer()
            launchAtLogin = LoginItem.isEnabled
            syncDirectory = syncService.syncDirectory
        }
        .onDisappear {
            stopStatusTimer()
        }
    }

    // MARK: - 通用

    private var generalSection: some View {
        Section {
            Toggle("开机时启动", isOn: Binding(
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
            .help("登录后自动在菜单栏运行 ntfyx")

            if let loginError {
                Text(loginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Toggle("默认展开消息全文", isOn: $expandByDefault)
                .help("长消息进入通知历史时即完整显示；单条仍可点击「收起」折回")

            LabeledContent("消息字号") {
                HStack(spacing: 8) {
                    Slider(value: $messageFontSize, in: 11...20, step: 1)
                        .frame(width: 160)
                    Text("\(Int(messageFontSize)) pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .help("通知历史中消息正文的字体大小，Markdown 标题随字号等比缩放")
        } header: {
            Text("通用")
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
                Label("添加服务器", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        } header: {
            HStack {
                Text("ntfy 服务器")
                if viewModel.hasUnsavedChanges {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                        .help("有未保存的更改")
                }
            }
        }
    }

    // MARK: - iCloud 同步

    private var iCloudSyncSection: some View {
        Section {
            Toggle("通过 iCloud 同步配置", isOn: Binding(
                get: { syncService.isEnabled },
                set: { syncService.setEnabled($0) }
            ))
            .help("在各台 Mac 之间同步服务器与主题配置。消息不经 iCloud，仍直接从 ntfy 服务器获取。")

            if syncService.isEnabled {
                LabeledContent("同步文件夹") {
                    HStack(spacing: 8) {
                        Text(syncDirectory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 250, alignment: .trailing)
                        Button("选择…") { chooseSyncDirectory() }
                    }
                }

                if !syncService.directoryOverride.isEmpty {
                    Button("改用 iCloud Drive") {
                        syncService.setDirectory("")
                        syncDirectory = syncService.syncDirectory
                    }
                    .buttonStyle(.borderless)
                }

                syncStatusRow

                Button {
                    syncService.syncNow()
                } label: {
                    Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)

                Text("同步文件里包含服务器令牌，iCloud Drive 上的这份内容是明文。脚本、图标路径、通知动作和本地服务端口只留在本机，不参与同步。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("iCloud 同步")
        }
    }

    @ViewBuilder
    private var syncStatusRow: some View {
        switch syncService.status {
        case .off:
            EmptyView()
        case .waiting:
            Label("等待首次同步…", systemImage: "icloud.and.arrow.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .syncing:
            Label("正在同步…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .synced(let date):
            Label("上次同步：\(SyncTimeFormat.string(date))", systemImage: "checkmark.icloud.fill")
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
        panel.prompt = "选择"
        panel.message = "选择存放 ntfyx 同步配置文件的文件夹"
        panel.directoryURL = URL(fileURLWithPath: syncService.syncDirectory, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        syncService.setDirectory(url.path)
        syncDirectory = syncService.syncDirectory
    }

    // MARK: - 本地通知服务

    private var localServerSection: some View {
        Section {
            HStack {
                Text("端口")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("留空以禁用", text: $viewModel.localServerPort)
                    .frame(width: 120)
                    .multilineTextAlignment(.trailing)
            }

            Text("端口范围须为 1024–65535；留空表示禁用本地通知服务。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isLocalServerEnabled {
                commandRow(
                    label: "curl",
                    command: "curl -X POST http://127.0.0.1:\(viewModel.localServerPort)/notify -H \"Content-Type: application/json\" -d '{\"title\": \"Hello\", \"message\": \"Hello from ntfyx!\"}'"
                )
            }
        } header: {
            Text("本地通知服务")
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
                    Text(copiedCommand == command ? "已拷贝" : "拷贝")
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
            .help("拷贝到剪贴板")
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
                    NSWorkspace.shared.open(URL(fileURLWithPath: ConfigManager.defaultConfigPath))
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.borderless)
                .help("在编辑器中打开配置文件")

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

                Button("取消") {
                    viewModel.cancel()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("保存") {
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

    // MARK: - Status refresh timer

    private func startStatusTimer() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in
                viewModel.refreshConnectionStates()
            }
        }
    }

    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }
}

// MARK: - Server row (collapsible)

private struct ServerRowView: View {
    @Binding var server: EditableServer
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showTokenSheet = false
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 10) {
                HStack {
                    Text("URL")
                        .foregroundStyle(.secondary)
                    TextField("", text: $server.url)
                }

                HStack {
                    if server.token.isEmpty {
                        Text("令牌：未配置")
                            .foregroundStyle(.secondary)
                    } else if server.storeInKeychain {
                        Label("令牌存储于钥匙串", systemImage: "key.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("令牌存储于配置文件", systemImage: "doc.text")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("管理…") {
                        showTokenSheet = true
                    }
                }

                Toggle("重连时拉取错过的消息", isOn: $server.fetchMissed)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        viewModel.testConnection(for: server)
                    } label: {
                        Label("测试连接", systemImage: "bolt.horizontal.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(server.url.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("按当前填写的地址与令牌探测服务器（无需先保存）")

                    testResultView(viewModel.serverTestStates[server.id])
                    Spacer()
                }

                restrictionRow(
                    title: "允许跳转方案",
                    offLabel: "默认 (http/https)",
                    placeholder: "http, https, myapp",
                    help: "限制该服务器消息可打开的 URL 方案；自定义列表留空等于全部禁止",
                    mode: $server.schemesMode,
                    input: $server.schemesInput
                )

                restrictionRow(
                    title: "信任域名",
                    offLabel: "不限制",
                    placeholder: "*.example.com, ntfy.sh",
                    help: "白名单：仅所列域名的链接可直接打开；*. 前缀匹配其子域；自定义列表留空等于全部禁止",
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
                        Label("添加主题", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button(role: .destructive) {
                        viewModel.removeServer(server)
                    } label: {
                        Text("删除此服务器")
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
                Text(server.url.isEmpty ? "新服务器" : server.url)
                    .fontWeight(.medium)
                Spacer()
                Text("\(server.topics.count) 个主题")
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
                Text("自定义列表").tag(URLRestriction.custom)
                Text("全部禁止").tag(URLRestriction.denyAll)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            if mode.wrappedValue == .custom {
                TextField(placeholder, text: input)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
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
                version.map { "连接正常 · v\($0)" } ?? "连接正常",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.caption)
        case .tokenRejected:
            Label("令牌被服务器拒绝", systemImage: "key.slash")
                .foregroundStyle(.red)
                .font(.caption)
        case .failed(let reason):
            Label("连接失败：\(reason)", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(1)
        case .none:
            EmptyView()
        }
    }

    private func connectionColor(for url: String) -> Color {
        guard !url.isEmpty, let state = viewModel.serverConnectionStates[url] else { return .gray }
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .red
        }
    }
}
