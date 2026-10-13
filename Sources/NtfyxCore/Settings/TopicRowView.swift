import SwiftUI
import AppKit

/// One topic in the server list: collapsed row showing name + configured-feature
/// badges; expanding reveals the graphical editor for every per-topic config field.
struct TopicRowView: View {
    @Binding var topic: EditableTopic
    var onDelete: (() -> Void)?
    var testState: SettingsViewModel.TopicTestState?
    var onSendTest: (() -> Void)?

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            TopicSettingsView(
                topic: $topic,
                onDelete: onDelete,
                testState: testState,
                onSendTest: onSendTest
            )
                .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                iconPreview
                Text(topic.name.isEmpty ? "新主题" : topic.name)
                    .foregroundStyle(topic.name.isEmpty ? .secondary : .primary)
                badges
                Spacer()
            }
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private var iconPreview: some View {
        if let path = topic.iconPath, !path.isEmpty, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        } else if let symbol = topic.iconSymbol, !symbol.isEmpty {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
        } else {
            Image(systemName: "bell")
                .foregroundStyle(.secondary)
                .frame(width: 16)
        }
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if topic.silent == true {
                badge("speaker.slash.fill", "静默")
            }
            if let script = topic.autoRunScript, !script.isEmpty {
                badge("terminal", "自动运行脚本")
            }
            if let count = topic.actions?.count, count > 0 {
                badge("button.programmable", "\(count) 个按钮动作")
            }
            if topic.fetchMissed == true {
                badge("arrow.triangle.2.circlepath", "重连时拉取错过的消息")
            }
            if let click = topic.clickUrl, case .custom = click {
                badge("link", "自定义点击链接")
            }
        }
    }

    private func badge(_ symbol: String, _ help: String) -> some View {
        Image(systemName: symbol)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .help(help)
    }
}

// MARK: - Topic settings editor

/// Graphical editor for the per-topic options of the config file:
/// name, fetch_missed, silent, icon_symbol, icon_path, click_url,
/// auto_run_script and actions.
struct TopicSettingsView: View {
    @Binding var topic: EditableTopic
    var onDelete: (() -> Void)?
    var testState: SettingsViewModel.TopicTestState?
    var onSendTest: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("名称") {
                TextField("主题名称", text: $topic.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }

            Toggle("重连时拉取错过的消息", isOn: Binding(
                get: { topic.fetchMissed ?? false },
                set: { topic.fetchMissed = $0 ? true : nil }
            ))
            .foregroundStyle(.secondary)

            Toggle("静默（不弹通知横幅）", isOn: Binding(
                get: { topic.silent ?? false },
                set: { topic.silent = $0 ? true : nil }
            ))
            .foregroundStyle(.secondary)

            if let onSendTest {
                HStack(spacing: 8) {
                    Button {
                        onSendTest()
                    } label: {
                        Label("发送测试通知", systemImage: "paperplane")
                    }
                    .buttonStyle(.borderless)
                    .disabled(topic.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("向该主题发布一条测试消息；已订阅的主题会随即弹出横幅（无需先保存）")

                    testResultView
                    Spacer()
                }
            }

            Divider()

            // Icons
            LabeledContent("SF Symbol 图标") {
                HStack(spacing: 6) {
                    if let symbol = topic.iconSymbol, !symbol.isEmpty {
                        Image(systemName: symbol)
                            .foregroundStyle(.secondary)
                    }
                    TextField("bell.badge", text: textBinding(\.iconSymbol))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .help("SF Symbol 名称，留空则不设置")
                }
            }

            LabeledContent("图片图标") {
                pathRow(
                    prompt: "图标文件",
                    text: textBinding(\.iconPath),
                    onPick: { topic.iconPath = pickFile() }
                )
                .help("本地图标图片文件路径")
            }

            Divider()

            // Click behaviour
            LabeledContent("点击行为") {
                Picker("", selection: clickBinding) {
                    Text("打开消息自带链接").tag(ClickMode.defaultOpen)
                    Text("不打开任何内容").tag(ClickMode.disabled)
                    Text("自定义 URL…").tag(ClickMode.custom)
                }
                .labelsHidden()
                .fixedSize()
            }
            if clickBinding.wrappedValue == .custom {
                TextField("https://…", text: customURLBinding)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            LabeledContent("自动运行脚本") {
                pathRow(
                    prompt: "脚本文件",
                    text: textBinding(\.autoRunScript),
                    onPick: { topic.autoRunScript = pickFile() }
                )
                .help("每条消息到达时执行的脚本")
            }

            Divider()

            // Actions
            VStack(alignment: .leading, spacing: 6) {
                Text("按钮动作")
                    .font(.callout.weight(.medium))
                Text("配置里定义的按钮会覆盖消息自带的动作。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Array(actionsBinding.wrappedValue.enumerated()), id: \.offset) { index, _ in
                    ActionEditorRow(
                        action: Binding(
                            get: { actionsBinding.wrappedValue[index] },
                            set: { actionsBinding.wrappedValue[index] = $0 }
                        ),
                        onDelete: {
                            var actions = actionsBinding.wrappedValue
                            actions.remove(at: index)
                            actionsBinding.wrappedValue = actions
                        }
                    )
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                }

                Button {
                    actionsBinding.wrappedValue.append(
                        NotificationAction(title: "", type: "view")
                    )
                } label: {
                    Label("添加按钮动作", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            if let onDelete {
                Divider()
                Button("删除此主题", role: .destructive, action: onDelete)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    // MARK: Test notification result

    @ViewBuilder
    private var testResultView: some View {
        switch testState {
        case .sending:
            ProgressView().controlSize(.small)
        case .success:
            Label("已发布，等待横幅", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let reason):
            Label("发送失败：\(reason)", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(1)
        case .none:
            EmptyView()
        }
    }

    // MARK: Bindings

    private enum ClickMode {
        case defaultOpen, disabled, custom
    }

    private var clickBinding: Binding<ClickMode> {
        Binding(
            get: {
                switch topic.clickUrl {
                case .disabled: return .disabled
                case .custom: return .custom
                case .enabled, nil: return .defaultOpen
                }
            },
            set: { mode in
                switch mode {
                case .defaultOpen: topic.clickUrl = nil
                case .disabled: topic.clickUrl = .disabled
                case .custom: topic.clickUrl = .custom("")
                }
            }
        )
    }

    private var customURLBinding: Binding<String> {
        Binding(
            get: {
                if case .custom(let url) = topic.clickUrl { return url }
                return ""
            },
            set: { topic.clickUrl = .custom($0) }
        )
    }

    private var actionsBinding: Binding<[NotificationAction]> {
        Binding(
            get: { topic.actions ?? [] },
            set: { topic.actions = $0.isEmpty ? nil : $0 }
        )
    }

    private func textBinding(_ keyPath: WritableKeyPath<EditableTopic, String?>) -> Binding<String> {
        Binding(
            get: { topic[keyPath: keyPath] ?? "" },
            set: { topic[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    @ViewBuilder
    private func pathRow(prompt: String, text: Binding<String>, onPick: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
            Button("选择…", action: onPick)
                .fixedSize()
        }
        .frame(width: 340)
    }

    private func pickFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

// MARK: - Single action editor

private struct ActionEditorRow: View {
    @Binding var action: NotificationAction
    var onDelete: () -> Void

    private static let types: [(value: String, label: String)] = [
        ("view", "打开链接"),
        ("script", "运行脚本"),
        ("applescript", "AppleScript"),
        ("shortcut", "快捷指令")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("按钮名称", text: $action.title)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Picker("", selection: $action.type) {
                    ForEach(Self.types, id: \.value) { type in
                        Text(type.label).tag(type.value)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("删除此按钮")
            }

            switch action.type {
            case "view":
                TextField("https://…", text: field(\.url))
                    .textFieldStyle(.roundedBorder)
            case "script":
                pathField("脚本文件", key: \.path)
            case "applescript":
                // `path` runs a .scpt file; `script` is inline source.
                VStack(alignment: .leading, spacing: 4) {
                    pathField("脚本文件（可选）", key: \.path)
                    TextField("或直接输入 AppleScript 源码", text: field(\.script), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                        .font(.system(.caption, design: .monospaced))
                }
            case "shortcut":
                TextField("macOS 快捷指令名称", text: field(\.name))
                    .textFieldStyle(.roundedBorder)
            default:
                EmptyView()
            }
        }
        .onChange(of: action.type) { _, newValue in
            // Drop fields that don't belong to the newly chosen type.
            switch newValue {
            case "view": action.path = nil; action.name = nil; action.script = nil
            case "script": action.url = nil; action.name = nil; action.script = nil
            case "applescript": action.url = nil; action.name = nil
            case "shortcut": action.url = nil; action.path = nil; action.script = nil
            default: break
            }
        }
    }

    private func field(_ keyPath: WritableKeyPath<NotificationAction, String?>) -> Binding<String> {
        Binding(
            get: { action[keyPath: keyPath] ?? "" },
            set: { action[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func pathField(_ prompt: String, key: WritableKeyPath<NotificationAction, String?>) -> some View {
        HStack(spacing: 6) {
            TextField(prompt, text: field(key))
                .textFieldStyle(.roundedBorder)
            Button("选择…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                if panel.runModal() == .OK {
                    action[keyPath: key] = panel.url?.path
                }
            }
            .fixedSize()
        }
    }
}
