import XCTest

/// An `XCTestExpectation` that tracks whether it has been fulfilled, so test code can
/// wait on it without XCTest's async machinery.
final class TrackableExpectation: XCTestExpectation {
    private let lock = NSLock()
    private var fulfilled = false

    override func fulfill() {
        lock.lock(); fulfilled = true; lock.unlock()
        super.fulfill()
    }

    var isFulfilled: Bool {
        lock.lock(); defer { lock.unlock() }; return fulfilled
    }
}

/// Replaces XCTest's async `fulfillment(of:timeout:)` in these suites.
///
/// Suspending on that API enters XCTest's async error-observation machinery, whose
/// task-dealloc path aborts the whole test process with "freed pointer was not the
/// last allocation" (Swift runtime task-stack LIFO check; the same abort is recorded
/// on the OneShotFulfillment comment in NtfyClientTests, and upstream in the
/// swiftlang/swift#92017 family). It reproduces deterministically on the CI runners
/// and never locally, so the waiting is done without that machinery: poll the
/// expectations and fail the test on timeout — same semantics, no XCTest async wait.
func waitForAll(
    _ expectations: [TrackableExpectation], timeout: TimeInterval,
    file: StaticString = #filePath, line: UInt = #line
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !expectations.allSatisfy(\.isFulfilled) && Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(
        expectations.allSatisfy(\.isFulfilled),
        "expectations not all fulfilled within \(timeout)s",
        file: file, line: line
    )
}
