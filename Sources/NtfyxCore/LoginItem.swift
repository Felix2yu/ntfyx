import Foundation
import ServiceManagement

/// Launch-at-login toggle backed by SMAppService (macOS 13+).
/// Only meaningful inside a proper .app bundle; `swift run` builds fail with
/// a LaunchServices error, which is surfaced to the caller instead of crashing.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or a user-facing error message.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "设置开机启动失败：\(error.localizedDescription)"
        }
    }
}
