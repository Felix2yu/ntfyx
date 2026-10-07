import XCTest
@testable import ntfyx

/// A `since` replay can carry tens of thousands of messages while its banner is decided, and
/// the decision only ever needs the totals plus, at most, the first few messages. These cover
/// the tally that replaced holding the whole replay in memory.
final class CatchUpTallyTests: XCTestCase {

    private func message(id: String, topic: String) -> NtfyMessage {
        NtfyMessage(
            id: id, time: 1_700_000_000, event: "message", topic: topic,
            message: "body", title: nil, priority: 3, tags: nil,
            click: nil, actions: nil, attachment: nil, contentType: nil, sequenceId: nil
        )
    }

    func testTallyKeepsOnlyTheHeadOfALargeReplay() {
        var tally = CatchUpTally()
        for index in 0..<5_000 { tally.add(message(id: "m\(index)", topic: "alerts")) }

        XCTAssertEqual(tally.count, 5_000)
        XCTAssertEqual(tally.entries.count, Ntfyx.catchUpIndividualBannerLimit)
        XCTAssertEqual(tally.entries.map(\.id), ["m0", "m1", "m2"])
    }

    /// A handful of messages missed while the app was away still gets real banners, so the
    /// entries under the limit must survive intact.
    func testTallyWithinTheIndividualLimitKeepsEveryMessage() {
        let limit = Ntfyx.catchUpIndividualBannerLimit
        var tally = CatchUpTally()
        for index in 0..<limit { tally.add(message(id: "m\(index)", topic: "alerts")) }

        XCTAssertEqual(tally.count, limit)
        XCTAssertEqual(tally.entries.count, limit)
    }

    func testTallyCountsEachTopicOnce() {
        var tally = CatchUpTally()
        for topic in ["builds", "builds", "alerts"] {
            tally.add(message(id: UUID().uuidString, topic: topic))
        }

        XCTAssertEqual(tally.count, 3)
        XCTAssertEqual(tally.topics, ["builds", "alerts"])
    }
}
