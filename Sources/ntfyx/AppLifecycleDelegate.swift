import AppKit
import SwiftUI
import NtfyxCore

/// SwiftUI adaptor that owns only what SwiftUI scenes cannot express:
/// activation policy per launch mode, service startup once the run loop is running,
/// Dock reopen, and the "closing the last window demotes a `serve` process back to the
/// menu bar" policy.
@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private let mode = AppMode.parse(CommandLine.arguments)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The run loop is already running here, so the old 0.1 s startup timers are gone.
        AppMode.configure(arguments: CommandLine.arguments)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            // willClose posts while the window is still visible; hop one run loop turn so
            // the check runs after close() actually orders it out.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000)
                if !AppMode.isDockApp, !NSApp.windows.contains(where: { $0.isVisible }) {
                    _ = NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        switch mode {
        case .dock:
            Log.info("正在启动 ntfyx 服务…")
            AppEnvironment.shared.boot(configPath: nil)
            AppEnvironment.shared.startService()
            if AppEnvironment.shared.firstLaunch {
                // Nothing to read yet; the point is to get the first subscription in.
                // Wait a beat for the SwiftUI Settings scene to register its action,
                // mirroring the history-scene delay below.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    AppEnvironment.openSettings()
                }
            } else {
                // The history scene is a single-instance Window, so this is idempotent
                // even when SwiftUI has already restored the window from last session.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    AppEnvironment.shared.router.requestHistory()
                }
            }

        case .serve(let configPath):
            AppEnvironment.shared.boot(configPath: configPath)
            AppEnvironment.shared.startService()

        case .testNotify(let topic):
            TestNotify.run(topic: topic)

        case .help, .redirected, .unknown:
            // Handled in NtfyxApp.init before the app finishes launching.
            break
        }
    }

    /// Clicking the Dock icon with no visible window brings the history window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if AppMode.isDockApp && !flag {
            AppEnvironment.shared.router.requestHistory()
        }
        return true
    }

    /// Suppress SwiftUI's automatic "untitled" window both at launch and on
    /// reopen. The history scene is opened explicitly by the router (first launch /
    /// reopen / menu), and `serve` must never sprout a window on its own.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return false
    }
}
