import UserNotifications
import XCTest
@testable import NtfyxCore

/// Pure-reducer tests for the notification-permission window state machine
/// (replaces the old AppKit-window PermissionHelper tests: no NSWindow, no delegate,
/// no deferred Tasks).
@MainActor
final class PermissionPromptStateTests: XCTestCase {

    // MARK: - Initial status

    func testInitialStatusTransitions() {
        XCTAssertEqual(
            PermissionPromptState.reduce(.checking, .statusLoaded(.authorized)),
            .finished(true)
        )
        XCTAssertEqual(
            PermissionPromptState.reduce(.checking, .statusLoaded(.notDetermined)),
            .readyToRequest
        )
        XCTAssertEqual(
            PermissionPromptState.reduce(.checking, .statusLoaded(.denied)),
            .denied
        )
        // Provisional/ephemeral are not a full grant: the service starts clients only
        // for .authorized, so the prompt closes with a denial.
        XCTAssertEqual(
            PermissionPromptState.reduce(.checking, .statusLoaded(.provisional)),
            .finished(false)
        )
    }

    // MARK: - Happy path

    func testGrantFlow() {
        var phase: PermissionPromptState.Phase = .checking
        phase = PermissionPromptState.reduce(phase, .statusLoaded(.notDetermined))
        phase = PermissionPromptState.reduce(phase, .requestTapped)
        XCTAssertEqual(phase, .requesting)
        phase = PermissionPromptState.reduce(phase, .requestCompleted(granted: true))
        XCTAssertEqual(phase, .finished(true))
    }

    // MARK: - Denial and failure

    func testDeniedAndFailureFlow() {
        var phase = PermissionPromptState.reduce(.readyToRequest, .requestTapped)
        phase = PermissionPromptState.reduce(phase, .requestCompleted(granted: false))
        XCTAssertEqual(phase, .denied)

        var failed = PermissionPromptState.reduce(.requesting, .requestFailed)
        XCTAssertEqual(failed, .denied)

        // From the denied phase the user can only open System Settings; further
        // request events must not resurrect the flow.
        failed = PermissionPromptState.reduce(failed, .requestTapped)
        XCTAssertEqual(failed, .denied)
        failed = PermissionPromptState.reduce(failed, .requestCompleted(granted: true))
        XCTAssertEqual(failed, .denied)
    }

    // MARK: - Close semantics (old window-delegate guarantees)

    func testCloseReportsCorrectOutcome() {
        // Title-bar close before any result abandons the flow as a denial.
        XCTAssertFalse(PermissionPromptState.outcomeOnClose(phase: .checking))
        XCTAssertFalse(PermissionPromptState.outcomeOnClose(phase: .readyToRequest))
        XCTAssertFalse(PermissionPromptState.outcomeOnClose(phase: .requesting))
        XCTAssertFalse(PermissionPromptState.outcomeOnClose(phase: .denied))

        // A programmatic finish must not be mistaken for the user walking away:
        // the window closes itself, and the close must carry the finished result.
        XCTAssertTrue(PermissionPromptState.outcomeOnClose(phase: .finished(true)))
        XCTAssertFalse(PermissionPromptState.outcomeOnClose(phase: .finished(false)))
    }

    // MARK: - ObservableObject wrapper

    func testObservableStateSendAndReset() {
        let state = PermissionPromptState()
        XCTAssertEqual(state.phase, .checking)

        state.send(.statusLoaded(.notDetermined))
        XCTAssertEqual(state.phase, .readyToRequest)
        state.send(.statusLoaded(.denied)) // ignored in this phase
        XCTAssertEqual(state.phase, .readyToRequest)

        state.reset()
        XCTAssertEqual(state.phase, .checking)
        state.send(.statusLoaded(.authorized))
        XCTAssertEqual(state.phase, .finished(true))
        // Finished is terminal.
        state.send(.requestTapped)
        XCTAssertEqual(state.phase, .finished(true))
    }
}
