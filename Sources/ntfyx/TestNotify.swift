import AppKit
import NtfyxCore

/// The `test-notify` launch mode: make sure notification authorization is in place
/// through the SwiftUI permission scene, deliver one test notification, then terminate.
@MainActor
enum TestNotify {
    static func run(topic: String?) {
        guard let topic else {
            print("用法：ntfyx test-notify --topic <NAME>")
            exit(1)
        }

        print("🚀 正在通过 GUI 窗口请求通知权限…")

        Task { @MainActor in
            let granted = await PermissionPromptCoordinator.shared.request()
            if granted {
                let notificationManager = NotificationManager.shared
                notificationManager.showTestNotification(topic: topic)
                print("✅ 已发送主题 \(topic) 的测试通知")
                // Give the notification a moment to be delivered, then exit cleanly.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                NSApp.terminate(nil)
            } else {
                print("❌ 通知权限被拒绝")
                print("")
                print("💡 应用现在应已出现在 系统设置 → 通知 中")
                print("   请在其中开启通知后重试。")
                NSApp.terminate(nil)
            }
        }
    }
}
