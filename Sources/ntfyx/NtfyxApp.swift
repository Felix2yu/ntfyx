import SwiftUI
import NtfyxCore

@main
struct NtfyxApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @State private var env = AppEnvironment.shared

    init() {
        // Commands that do not need the app lifecycle exit before scenes come up.
        switch AppMode.parse(CommandLine.arguments) {
        case .help:
            CommandLineIO.printUsage()
            exit(0)
        case .redirected(let command):
            CommandLineIO.printRedirected(command)
            exit(1)
        case .unknown(let command):
            CommandLineIO.printUnknown(command)
            exit(1)
        case .dock, .serve, .testNotify:
            break
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenuView()
                .environment(env)
        } label: {
            MenuBarLabel()
                .environment(env)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            NtfyxCommands()
        }

        WindowGroup(id: "history") {
            HistorySceneRoot()
                .environment(env)
        }
        .defaultSize(width: 950, height: 620)

        Window("关于 ntfyx", id: "about") {
            AboutView()
                .environment(env)
        }
        .windowResizability(.contentSize)

        Window("ntfyx - 通知权限设置", id: "permission") {
            PermissionPromptView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsRootView(
                connections: env.connections,
                configStore: env.configStore,
                syncService: env.configSync
            )
        }
    }
}
