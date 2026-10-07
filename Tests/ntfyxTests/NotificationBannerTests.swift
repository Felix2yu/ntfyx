import XCTest
@testable import ntfyx

/// Banners are keyed by the ntfy message id so a read or delete on any device can withdraw
/// them. Talking to User Notifications needs a real app bundle, so these tests cover the
/// pure identifier mapping the revocation path depends on.
final class NotificationBannerTests: XCTestCase {

    func testIdentifierIsDerivedFromMessageID() {
        XCTAssertEqual(NotificationManager.identifier(forMessageID: "abc123"), "ntfy:abc123")
    }

    func testDistinctMessagesGetDistinctIdentifiers() {
        XCTAssertNotEqual(
            NotificationManager.identifier(forMessageID: "abc123"),
            NotificationManager.identifier(forMessageID: "xyz789")
        )
    }

    // MARK: - Icon files

    /// Notification Center moves an attachment's file into its own store when the request is
    /// added, so each banner writes the cached PNG back to this path. The name has to be stable
    /// per symbol and must not let two symbols collide on one file.
    func testIconFileNameIsStableAndDistinctPerSymbol() {
        XCTAssertEqual(NotificationManager.iconFileName(for: "bell.fill"), "bell.fill.png")
        XCTAssertNotEqual(
            NotificationManager.iconFileName(for: "bell.fill"),
            NotificationManager.iconFileName(for: "bell.badge.fill")
        )
    }

    func testIconFileNameReplacesPathSeparators() {
        let name = NotificationManager.iconFileName(for: "../../etc/passwd")
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasSuffix(".png"))
    }

    // MARK: - Priority handling (audit 1.5)

    func testMinPriorityIsSuppressed() {
        XCTAssertEqual(NotificationManager.priorityHandling(for: 1), .suppressed)
        XCTAssertEqual(NotificationManager.priorityHandling(for: 0), .suppressed)
    }

    func testLowPriorityIsPassive() {
        XCTAssertEqual(NotificationManager.priorityHandling(for: 2), .passive)
    }

    func testDefaultAndHighPrioritiesAreNormal() {
        XCTAssertEqual(NotificationManager.priorityHandling(for: nil), .normal)
        XCTAssertEqual(NotificationManager.priorityHandling(for: 3), .normal)
        XCTAssertEqual(NotificationManager.priorityHandling(for: 4), .normal)
        XCTAssertEqual(NotificationManager.priorityHandling(for: 5), .normal)
    }

    // MARK: - Action categories

    private func action(label: String, action: String = "http") -> NtfyMessage.NtfyAction {
        NtfyMessage.NtfyAction(
            action: action, label: label, url: "https://example.com", method: "POST",
            headers: nil, body: nil, clear: nil
        )
    }

    /// Two messages offering the same buttons have the same category: the identifiers are
    /// `ntfy-action-<index>` and each notification carries its own URLs in userInfo, so the
    /// category only describes the labels. Keying it by message id registered one category per
    /// message and never removed any.
    func testSameActionShapeSharesOneCategory() {
        XCTAssertEqual(
            NotificationManager.messageActionCategoryID([action(label: "部署"), action(label: "查看")]),
            NotificationManager.messageActionCategoryID([action(label: "部署"), action(label: "查看")])
        )
    }

    func testDifferentActionShapesGetDifferentCategories() {
        XCTAssertNotEqual(
            NotificationManager.messageActionCategoryID([action(label: "部署")]),
            NotificationManager.messageActionCategoryID([action(label: "回滚")])
        )
        XCTAssertNotEqual(
            NotificationManager.messageActionCategoryID([action(label: "部署")]),
            NotificationManager.messageActionCategoryID([action(label: "部署", action: "view")])
        )
    }
}
