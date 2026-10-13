import AppKit
import UserNotifications

/// Thin, replaceable wrapper around User Notifications authorization (audit A1 target split:
/// the prompt UI lives in the app target; the system API surface lives here so it can be
/// faked in tests).
@MainActor
public final class PermissionService {
    public static let shared = PermissionService()

    public init() {}

    public func currentStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    public func request() async throws -> Bool {
        try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}
