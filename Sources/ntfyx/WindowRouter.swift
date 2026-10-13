import SwiftUI
import Observation

/// Routes window-opening requests coming from outside the scene tree
/// (the app delegate's first-launch / reopen logic) to SwiftUI `openWindow`.
///
/// A request bumps `token`; the always-alive menu bar label observes it and calls
/// `openWindow(id:)` on the router's behalf.
@MainActor
@Observable
final class WindowRouter {
    enum Route: Equatable {
        case history(topic: String?)
        case settings
        case about
        case permission
    }

    private(set) var token = 0
    private(set) var pendingRoute: Route?

    func request(_ route: Route) {
        pendingRoute = route
        token += 1
    }

    /// Pops the pending route, if any.
    func dequeue() -> Route? {
        let route = pendingRoute
        pendingRoute = nil
        return route
    }

    func requestHistory(selectingTopic topic: String? = nil) {
        request(.history(topic: topic))
    }

    func requestSettings() {
        request(.settings)
    }

    func requestAbout() {
        request(.about)
    }

    func requestPermission() {
        request(.permission)
    }
}
