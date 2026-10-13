import Foundation

/// Sliding-window limiter deciding whether a notification gets its own banner or is
/// folded into a burst summary. Catching up on several topics at once (`since=all`)
/// can deliver hundreds of messages within seconds; posting one sound-bearing banner
/// per message floods notificationcenterd, which freezes the banner UI and keeps
/// playing queued sounds even after the app exits.
///
/// Every delivery runs through `NotificationManager` on the main actor, so the limiter
/// lives there too — no lock needed (audit B1/#14).
@MainActor
final class NotificationThrottle {
    enum Decision: Equatable {
        case individual
        /// Fold into the shared burst summary. `absorbed` carries the identifiers of the
        /// banners already shown during this storm (only on the message that starts it),
        /// so the summary can replace them instead of leaving orphans behind.
        case coalesced(count: Int, topics: [String], firstOfBurst: Bool, absorbed: [String])
    }

    let window: TimeInterval
    private let threshold: Int

    private var recent: [Date] = []
    private var shownIndividually: [(date: Date, identifier: String)] = []
    private var burstCount = 0
    private var burstTopics: [String] = []
    private var isBursting = false

    init(window: TimeInterval = 10, threshold: Int = 8) {
        self.window = window
        self.threshold = threshold
    }

    /// Records one about-to-be-shown message and decides how to present it.
    /// High priorities (4/5) always stay standalone — a burst must not swallow an alert.
    func register(topic: String, priority: Int?, identifier: String, now: Date = Date()) -> Decision {
        recent = recent.filter { now.timeIntervalSince($0) <= window }
        shownIndividually = shownIndividually.filter { now.timeIntervalSince($0.date) <= window }

        // A full silent window means the previous storm is over.
        if isBursting, recent.isEmpty {
            isBursting = false
            burstCount = 0
            burstTopics = []
        }
        recent.append(now)

        if let priority, priority >= 4 {
            return .individual
        }

        if isBursting {
            burstCount += 1
            if !burstTopics.contains(topic) {
                burstTopics.append(topic)
            }
            return .coalesced(count: burstCount, topics: burstTopics, firstOfBurst: false, absorbed: [])
        }

        if recent.count >= threshold {
            isBursting = true
            burstCount = 1
            burstTopics = [topic]
            // Earlier messages already got banners of their own; withdraw them so the
            // storm leaves exactly one trace behind.
            let absorbed = shownIndividually.map { $0.identifier }
            shownIndividually.removeAll()
            return .coalesced(count: burstCount, topics: burstTopics, firstOfBurst: true, absorbed: absorbed)
        }

        shownIndividually.append((now, identifier))
        return .individual
    }
}
