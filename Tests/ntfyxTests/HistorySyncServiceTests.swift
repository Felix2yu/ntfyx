import XCTest
@testable import ntfyx

/// Sync-failure recovery (audit 2.5): a rate-limited sync retries itself once the
/// window lapses; a plain failure stays put for the manual retry button.
@MainActor
final class HistorySyncServiceTests: XCTestCase {

    private final class Box: @unchecked Sendable {
        var attempts = 0
    }

    private func makeMessage(id: String) -> NtfyMessage {
        NtfyMessage(
            id: id, time: Int(Date().timeIntervalSince1970), event: "message", topic: "alerts",
            message: "body", title: nil, priority: nil, tags: nil, click: nil, actions: nil,
            attachment: nil, contentType: nil, sequenceId: nil
        )
    }

    private func makeFixture() throws -> (HistorySyncService, MessageStore, TopicRef) {
        let store = try MessageStore.inMemory()
        let service = HistorySyncService(store: store)
        return (service, store, TopicRef(serverURL: "https://s.example", topic: "alerts"))
    }

    private func waitUntilCompleted(
        _ service: HistorySyncService, _ ref: TopicRef, timeout: TimeInterval = 6
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .completed = service.progress(for: ref).phase { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    func testRateLimitedSyncAutoRetriesThenCompletes() async throws {
        let (service, store, ref) = try makeFixture()
        let box = Box()
        let message = makeMessage(id: "m1")
        service.poll = { _, _, _, _, onEvents in
            box.attempts += 1
            if box.attempts == 1 {
                throw NtfyPollClient.PollError.http(status: 429, retryAfter: 1)
            }
            try await onEvents([message])
            var result = NtfyPollClient.PollResult()
            result.messageCount = 1
            result.newestMessage = message
            return result
        }

        await service.syncIncremental(ref)
        XCTAssertEqual(service.progress(for: ref).phase, .rateLimited(retryAfter: 1))

        let done = await waitUntilCompleted(service, ref)
        XCTAssertTrue(done, "auto-retry should complete the sync after the rate-limit window")
        XCTAssertEqual(box.attempts, 2)
        let stored = try await store.messages(serverURL: "https://s.example", topic: "alerts")
        XCTAssertEqual(stored.map { $0.message.id }, ["m1"])
    }

    func testAutoRetryStopsAtBudgetAndManualSyncResetsIt() async throws {
        let (service, _, ref) = try makeFixture()
        let box = Box()
        service.poll = { _, _, _, _, _ in
            box.attempts += 1
            throw NtfyPollClient.PollError.http(status: 429, retryAfter: 1)
        }

        await service.syncIncremental(ref)  // attempt 1, then two scheduled auto retries
        let quietDeadline = Date().addingTimeInterval(5)
        while Date() < quietDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(box.attempts, 1 + HistorySyncService.autoRetryLimit)

        await service.syncIncremental(ref)  // manual retry is always allowed again
        XCTAssertEqual(box.attempts, 2 + HistorySyncService.autoRetryLimit)
    }

    func testPlainFailureDoesNotAutoRetry() async throws {
        let (service, _, ref) = try makeFixture()
        let box = Box()
        service.poll = { _, _, _, _, _ in
            box.attempts += 1
            throw NtfyPollClient.PollError.http(status: 500, retryAfter: nil)
        }

        await service.syncIncremental(ref)
        guard case .failed = service.progress(for: ref).phase else {
            return XCTFail("expected a failed phase without a retry schedule")
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(box.attempts, 1)
    }
}
