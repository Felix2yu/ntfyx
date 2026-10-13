import SwiftUI
import NtfyxCore

/// Main menu (Dock mode) commands. The Settings…/Services/Hide/Quit/Edit/Window groups
/// stay system-provided; we only replace About (opens the SwiftUI about scene) and the
/// File group (history / config actions). The same actions also live in the menu-bar
/// extra's menu, where keyboard shortcuts are attached explicitly.
struct NtfyxCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 ntfyx") {
                openWindow(id: "about")
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("通知历史…") {
                openWindow(id: "history")
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Divider()

            Button("重载配置") {
                // Commands are built outside the scene environment, so they take the
                // composition-root singleton directly (it is not a SwiftUI view layer).
                AppEnvironment.shared.reloadConfig()
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("在 Finder 中显示配置") {
                AppActions.showConfigInFinder()
            }

            Divider()

            Button("查看日志…") {
                AppActions.viewLogs()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .help) {
            Link("ntfyx 项目主页", destination: URL(string: "https://github.com/Felix2yu/ntfyx")!)
        }
    }
}
