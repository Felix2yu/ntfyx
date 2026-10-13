import Observation
import UserNotifications

/// Pure state machine behind the notification-permission window.
///
/// All transitions go through the static `reduce(_:_:)` function, which has no AppKit,
/// User Notifications or timing dependencies — no `asyncAfter`, no window delegates.
/// The app target's `PermissionPromptView` renders `phase` and feeds it `Event`s.
@MainActor
@Observable
public final class PermissionPromptState {
    public enum Phase: Equatable {
        /// Status is being queried before the first paint.
        case checking
        /// Status is `.notDetermined`: the "请求权限" button is enabled.
        case readyToRequest
        /// The system authorization dialog is up; the button is disabled.
        case requesting
        /// Authorization was refused (now or earlier): the button opens System Settings.
        case denied
        /// The flow is over; the window should close, carrying the grant outcome.
        case finished(Bool)
    }

    public enum Event: Equatable {
        case statusLoaded(UNAuthorizationStatus)
        case requestTapped
        case requestCompleted(granted: Bool)
        case requestFailed
    }

    public static func reduce(_ phase: Phase, _ event: Event) -> Phase {
        switch (phase, event) {
        case (.checking, .statusLoaded(let status)):
            switch status {
            case .authorized:
                return .finished(true)
            case .notDetermined:
                return .readyToRequest
            case .denied:
                return .denied
            case .provisional:
                // Not a full grant: the service starts clients only for .authorized.
                return .finished(false)
            @unknown default:
                return .finished(false)
            }

        case (.readyToRequest, .requestTapped):
            return .requesting

        case (.requesting, .requestCompleted(let granted)):
            return granted ? .finished(true) : .denied

        case (.requesting, .requestFailed):
            return .denied

        default:
            return phase
        }
    }

    /// Outcome the window close should report: an explicit `.finished` result wins
    /// (a programmatic close must not look like the user walking away); a title-bar
    /// close in every other phase abandons the flow as a denial.
    public static func outcomeOnClose(phase: Phase) -> Bool {
        if case .finished(let granted) = phase { return granted }
        return false
    }

    public private(set) var phase: Phase = .checking

    public init(phase: Phase = .checking) {
        self.phase = phase
    }

    public func send(_ event: Event) {
        phase = PermissionPromptState.reduce(phase, event)
    }

    public func reset() {
        phase = .checking
    }
}
