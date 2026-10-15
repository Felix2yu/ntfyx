import XCTest
@testable import NtfyxCore

/// The menu bar row must not widen the menu, so the timestamp drops whatever the context
/// already implies. These pin the three widths against a fixed `now`.
final class SyncTimeFormatTests: XCTestCase {
    private let now = SyncTimeFormatTests.date(2026, 10, 15, 17, 33)

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testTodayOmitsTheDate() {
        XCTAssertEqual(SyncTimeFormat.compactString(Self.date(2026, 10, 15, 9, 5), now: now), "09:05")
    }

    func testThisYearOmitsTheYear() {
        XCTAssertEqual(SyncTimeFormat.compactString(Self.date(2026, 3, 4, 8, 9), now: now), "3月4日 08:09")
    }

    func testOlderYearsKeepTheFullTimestamp() {
        let lastYear = Self.date(2025, 12, 31, 23, 59)
        XCTAssertEqual(SyncTimeFormat.compactString(lastYear, now: now), "2025年12月31日 23:59")
        XCTAssertEqual(SyncTimeFormat.string(lastYear), "2025年12月31日 23:59")
    }
}
