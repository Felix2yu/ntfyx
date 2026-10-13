import SwiftUI
import UserNotifications
import NtfyxCore

/// App-layer bridge between `AppCore.startService()` and the SwiftUI permission
/// `Window` scene: queries the current authorization status, opens the scene, and
/// suspends the caller until the flow resolves.
@MainActor
final class PermissionPromptCoordinator {
    static let shared = PermissionPromptCoordinator()

    let state = PermissionPromptState()

    private var continuation: CheckedContinuation<Bool, Never>?
    private var pendingStatus: UNAuthorizationStatus?

    private init() {}

    /// Returns `true` when notifications are already authorized or the prompt flow
    /// finishes with a grant.
    func request() async -> Bool {
        state.reset()
        let status = await PermissionService.shared.currentStatus()
        if status == .authorized {
            return true
        }
        // Route the scene open and park the status: the event is only dispatched once
        // the scene reports it is ready, so a terminal phase can never arrive before
        // the view (and the continuation below) exists to observe it.
        AppEnvironment.shared.router.requestPermission()
        pendingStatus = status

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// Called by the prompt scene when it first appears; feeds in the parked status.
    func sceneReady() {
        guard let status = pendingStatus else { return }
        pendingStatus = nil
        state.send(.statusLoaded(status))
    }

    /// Called by the view when a `.finished` phase lands: resolve *before* dismissing,
    /// so the window's own disappearance cannot overwrite the result.
    func resolveFromFinishedPhase() {
        guard case .finished(let granted) = state.phase else { return }
        resolve(granted)
    }

    /// Called when the window disappears (title-bar close / scene teardown): an
    /// explicit `.finished` result wins, otherwise the flow was abandoned as a denial.
    func resolveFromWindowClose() {
        resolve(PermissionPromptState.outcomeOnClose(phase: state.phase))
    }

    private func resolve(_ granted: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: granted)
    }
}
