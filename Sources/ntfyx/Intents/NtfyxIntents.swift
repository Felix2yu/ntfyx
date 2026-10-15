import AppIntents
import NtfyxCore

/// AppIntents surface for the Shortcuts app (and, once the app is signed with a
/// Developer ID as part of F1, Siri suggestions/donations). Every intent runs
/// without bringing the app to the front (`openAppWhenRun == false`) and only
/// touches main-actor services that are safe to call while menu-bar-only.
///
/// Note on ad-hoc builds: the intents are discoverable by the local Shortcuts
/// app, but cross-device donations and Siri suggestions remain limited until the
/// app ships under a proper signature (tracked as F1).

/// Pauses notification banners; subscriptions, history and the unread badge
/// keep working — exactly like the menu-bar pause item.
struct PauseNotificationsIntent: AppIntent {
    static let title: LocalizedStringResource = "暂停 ntfyx 通知"
    static let description = IntentDescription(
        "暂停 ntfyx 的通知横幅；订阅连接、历史记录与未读角标照常工作。"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationPause.shared.setPaused(true)
        return .result(dialog: "已暂停 ntfyx 通知横幅。订阅与历史记录不受影响。")
    }
}

/// Resumes notification banners.
struct ResumeNotificationsIntent: AppIntent {
    static let title: LocalizedStringResource = "恢复 ntfyx 通知"
    static let description = IntentDescription("恢复 ntfyx 的通知横幅展示。")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationPause.shared.setPaused(false)
        return .result(dialog: "已恢复 ntfyx 通知横幅。")
    }
}

/// Delivers one local test banner through `NotificationManager`, the same path
/// as the settings screen's test button — useful for checking notification
/// permission and Focus/banner behavior from an automation.
struct SendTestNotificationIntent: AppIntent {
    static let title: LocalizedStringResource = "发送 ntfyx 测试通知"
    static let description = IntentDescription(
        "立即向通知中心投递一条本地测试横幅，用于验证通知权限与展示效果。"
    )
    static let openAppWhenRun = false

    @Parameter(
        title: "主题",
        description: "测试通知中显示的 ntfy 主题名称",
        requestValueDialog: "要发送哪个主题的测试通知？"
    )
    var topic: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw $topic.needsValueError("请输入主题名称。")
        }
        NotificationManager.shared.showTestNotification(topic: trimmed)
        return .result(dialog: "已发送主题「\(trimmed)」的测试通知。")
    }
}

/// Fires one out-of-band configuration sync pass (ignores the debounce, like
/// the menu's "立即同步").
struct SyncNowIntent: AppIntent {
    static let title: LocalizedStringResource = "立即同步 ntfyx 配置"
    static let description = IntentDescription(
        "立即执行一次 iCloud 配置合并；不会等待同步结果，状态可在菜单中查看。"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = AppEnvironment.shared.configSync
        guard service.isEnabled else {
            return .result(dialog: "配置同步未开启，没有需要同步的内容。")
        }
        service.syncNow()
        return .result(dialog: "已触发一次 ntfyx 配置同步。")
    }
}
