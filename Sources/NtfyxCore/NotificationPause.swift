import Foundation

/// Menu-bar pause switch for notification banners.
///
/// While paused the subscriptions stay connected, and messages still land in the
/// history store and the unread badge — only the banner presentation is suppressed.
/// Persisted so a relaunch does not silently resume banner noise.
@MainActor
public final class NotificationPause {
    public static let shared = NotificationPause(defaults: .standard)

    private static let key = "ntfyNotificationsPaused"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var isPaused: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }

    /// Sets the banner pause state explicitly (used by the menu toggle and AppIntents).
    /// Returns the resulting state, which equals `paused`.
    @discardableResult
    public func setPaused(_ paused: Bool) -> Bool {
        isPaused = paused
        return paused
    }

    @discardableResult
    public func toggle() -> Bool {
        isPaused.toggle()
        return isPaused
    }
}
