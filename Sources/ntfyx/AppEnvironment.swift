import Foundation
import AppKit
import Observation
import NtfyxCore

/// Composition root for the running app process (audit B2).
///
/// Owns the live, observable service instances and hands them to SwiftUI through
/// `.environment(env)`; views never reach for a shared singleton themselves. The one
/// static `shared` instance exists for the pre-scene bootstrap paths (the app delegate
/// and the permission coordinator run before/outside the scene tree).
@MainActor
@Observable
final class AppEnvironment {
    static let shared = AppEnvironment()

    let router = WindowRouter()
    let connections = ConnectionRegistry()
    /// One in-memory configuration source for this process (audit E3); the sync facade
    /// and the coordinator share it, so settings saves and watcher reloads are the same
    /// state the SSE clients run on.
    let configStore = ConfigStore()
    let backgroundTasks = BackgroundTasks()
    let configSync: ConfigSyncService

    private(set) var ntfyx: Ntfyx?
    private(set) var firstLaunch = false
    /// Long-lived view model behind the history scene; prepared lazily when the scene opens.
    private(set) var historyVM: HistoryViewModel?

    private init() {
        configSync = ConfigSyncService(
            configStore: configStore,
            backgroundTasks: backgroundTasks
        )
    }

    /// Loads config, opens the history store and starts the watchers/sync facades.
    /// On an unusable config this never returns: `Ntfyx.serve` presents the fatal
    /// startup alert / CLI message and exits the process.
    func boot(configPath: String?) {
        let app = Ntfyx(
            connections: connections,
            configStore: configStore,
            configSync: configSync,
            backgroundTasks: backgroundTasks
        )
        app.serve(configPath: configPath)
        ntfyx = app
        firstLaunch = app.didCreateInitialConfig

        // Core views (e.g. HistoryViewModel) reload the running service through this hook.
        AppHooks.reloadConfig = { [weak self] in
            self?.ntfyx?.reloadConfig()
        }

        // The permission prompt is a SwiftUI scene the app target owns. A background
        // `serve` denial terminates the process here; core never calls exit() itself.
        AppHooks.requestNotificationPermission = {
            let granted = await PermissionPromptCoordinator.shared.request()
            if !granted && !AppMode.isDockApp {
                exit(1)
            }
            return granted
        }
    }

    func startService() {
        ntfyx?.startService()
    }

    func reloadConfig() {
        ntfyx?.reloadConfig()
    }

    /// Lazily builds (and afterwards reuses) the history scene's view model. Returns nil
    /// only during the brief window before the history store has opened.
    @discardableResult
    func makeHistoryViewModel() -> HistoryViewModel? {
        if let historyVM { return historyVM }
        guard let vm = ntfyx?.makeHistoryViewModel() else { return nil }
        historyVM = vm
        return vm
    }

    /// Scene task: waits for the store opened during `serve()` and then pins the shared
    /// view model onto `historyVM`, so the scene observes it directly (no 0.1 s polling).
    func prepareHistoryViewModel() async {
        while historyVM == nil, !Task.isCancelled {
            if makeHistoryViewModel() != nil { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Shows the SwiftUI Settings scene.
    ///
    /// On macOS 26 the classic `showSettingsWindow:` responder action is answered by
    /// `SwiftUI.AppDelegate` but does nothing; the real opener is the app-menu Settings
    /// item (`menuAction:` on a private SwiftUI target, keyEquivalent ","), so invoke
    /// that item directly.
    static func openSettings() {
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           let item = appMenu.items.first(where: { $0.keyEquivalent == "," }),
           let action = item.action,
           let target = item.target,
           NSApp.sendAction(action, to: target, from: item) {
            return
        }
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
