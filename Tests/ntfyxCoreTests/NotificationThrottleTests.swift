import XCTest
@testable import NtfyxCore

/// Catch-up fetches on several topics can deliver hundreds of messages at once. Each sound-
/// bearing banner is queued inside notificationcenterd, so a flood freezes the banner UI and
/// keeps playing sounds even after the app quits. The throttle folds a storm into one summary;
/// these tests cover that pure decision logic (talking to User Notifications needs a bundle).
@MainActor
final class NotificationThrottleTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func date(_ offset: TimeInterval) -> Date {
        t0.addingTimeInterval(offset)
    }

    private func id(_ n: Int) -> String { "ntfy:m\(n)" }

    func testMessagesBelowThresholdStayIndividual() {
        let throttle = NotificationThrottle(window: 10, threshold: 8)
        for i in 0..<7 {
            let decision = throttle.register(topic: "t\(i)", priority: 3, identifier: id(i), now: date(Double(i)))
            XCTAssertEqual(decision, .individual)
        }
    }

    func testThresholdTriggersCoalescedSummary() {
        let throttle = NotificationThrottle(window: 10, threshold: 8)
        for i in 0..<7 {
            _ = throttle.register(topic: "topic", priority: 3, identifier: id(i), now: date(Double(i)))
        }
        XCTAssertEqual(
            throttle.register(topic: "topic", priority: 3, identifier: id(7), now: date(7)),
            .coalesced(count: 1, topics: ["topic"], firstOfBurst: true, absorbed: (0..<7).map { id($0) })
        )
        XCTAssertEqual(
            throttle.register(topic: "other", priority: 3, identifier: id(8), now: date(8)),
            .coalesced(count: 2, topics: ["topic", "other"], firstOfBurst: false, absorbed: [])
        )
    }

    func testHighPriorityBypassesBurstAndIsNeverAbsorbed() {
        let throttle = NotificationThrottle(window: 10, threshold: 3)
        _ = throttle.register(topic: "a", priority: 3, identifier: id(0), now: date(0))
        _ = throttle.register(topic: "urgent", priority: 5, identifier: id(1), now: date(1))
        // The high-priority banner shown during ramp-up must survive the absorption sweep.
        XCTAssertEqual(
            throttle.register(topic: "a", priority: 3, identifier: id(2), now: date(2)),
            .coalesced(count: 1, topics: ["a"], firstOfBurst: true, absorbed: [id(0)])
        )
        XCTAssertEqual(throttle.register(topic: "urgent", priority: 5, identifier: id(3), now: date(3)), .individual)
        XCTAssertEqual(throttle.register(topic: "important", priority: 4, identifier: id(4), now: date(4)), .individual)
    }

    func testBurstStaysActiveWhileMessagesKeepArriving() {
        let throttle = NotificationThrottle(window: 10, threshold: 3)
        for i in 0..<3 {
            _ = throttle.register(topic: "a", priority: 3, identifier: id(i), now: date(Double(i)))
        }
        // Still storming 9s after the previous message → the next one keeps coalescing.
        XCTAssertEqual(
            throttle.register(topic: "a", priority: 3, identifier: id(9), now: date(11)).isCoalesced, true
        )
    }

    func testQuietWindowEndsBurstAndRestartsCounting() {
        let throttle = NotificationThrottle(window: 10, threshold: 3)
        for i in 0..<3 {
            _ = throttle.register(topic: "a", priority: 3, identifier: id(i), now: date(Double(i)))
        }
        // After a full silent window, normal messages get their own banners again.
        XCTAssertEqual(throttle.register(topic: "a", priority: 3, identifier: id(20), now: date(20)), .individual)
        XCTAssertEqual(throttle.register(topic: "a", priority: 3, identifier: id(21), now: date(21)), .individual)
    }

    func testAbsorbedListOnlyCoversTheCurrentStorm() {
        let throttle = NotificationThrottle(window: 10, threshold: 2)
        _ = throttle.register(topic: "a", priority: 3, identifier: id(0), now: date(0))
        // Storm 1 absorbs exactly the one ramp-up banner.
        XCTAssertEqual(
            throttle.register(topic: "a", priority: 3, identifier: id(1), now: date(1)).absorbed, [id(0)]
        )
        // A later storm only absorbs its own ramp-up banners.
        _ = throttle.register(topic: "a", priority: 3, identifier: id(30), now: date(30))
        XCTAssertEqual(
            throttle.register(topic: "a", priority: 3, identifier: id(31), now: date(31)).absorbed, [id(30)]
        )
    }
}

private extension NotificationThrottle.Decision {
    var isCoalesced: Bool {
        if case .coalesced = self { return true }
        return false
    }

    var absorbed: [String] {
        if case .coalesced(_, _, _, let absorbed) = self { return absorbed }
        return []
    }
}
