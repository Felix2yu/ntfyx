import XCTest
@testable import NtfyxCore

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

    // MARK: - Title fallback (中文备注)

    private func message(title: String?, tags: [String]? = nil) -> NtfyMessage {
        NtfyMessage(
            id: "m1", time: 1_700_000_000, event: "message", topic: "nightly-backup",
            message: "body", title: title, priority: 3, tags: tags,
            click: nil, actions: nil, attachment: nil, contentType: nil, sequenceId: nil
        )
    }

    func testTitlelessBannerIsNamedByTheTopicNote() {
        XCTAssertEqual(
            NotificationManager.bannerTitle(for: message(title: nil), topicLabel: "夜间备份"),
            "夜间备份"
        )
    }

    func testEmptyTitleCountsAsMissingAndFallsBack() {
        XCTAssertEqual(
            NotificationManager.bannerTitle(for: message(title: ""), topicLabel: "夜间备份"),
            "夜间备份"
        )
    }

    func testMessageTitleWinsOverTheTopicNote() {
        XCTAssertEqual(
            NotificationManager.bannerTitle(for: message(title: "备份失败"), topicLabel: "夜间备份"),
            "备份失败"
        )
    }

    func testTopicNoteKeepsTheTagEmojiPrefix() {
        let title = NotificationManager.bannerTitle(for: message(title: nil, tags: ["warning"]), topicLabel: "夜间备份")
        XCTAssertTrue(title.hasSuffix("夜间备份"), title)
        XCTAssertNotEqual(title, "夜间备份", "标签表情仍然要保留")
    }

    // MARK: - Body blank lines

    private func message(body: String?, contentType: String? = nil) -> NtfyMessage {
        NtfyMessage(
            id: "m1", time: 1_700_000_000, event: "message", topic: "nightly-backup",
            message: body, title: "发布新版本", priority: 3, tags: nil,
            click: nil, actions: nil, attachment: nil, contentType: contentType, sequenceId: nil
        )
    }

    /// Notification Center clips a long body to the first few lines and shows no ellipsis, so a
    /// paragraph break that lands on the last visible line left the box with an empty bottom row —
    /// a release banner ended in blank space while every other app's banner ended in text.
    func testMarkdownParagraphBreaksNeverReachTheBanner() {
        let markdown = "**仓库**: PelagicaApp/pelagica\n**版本**: 4.12.0 → 4.13.0\n"
            + "**发布时间**: 2026-10-16 14:09:31\n\n## 更新日志\n\n- 添加了选项\n"
        XCTAssertEqual(
            NotificationManager.bannerBody(for: message(body: markdown, contentType: "text/markdown")),
            "仓库: PelagicaApp/pelagica\n版本: 4.12.0 → 4.13.0\n"
                + "发布时间: 2026-10-16 14:09:31\n更新日志\n添加了选项"
        )
    }

    func testPlainTextBlankLinesAreDropped() {
        XCTAssertEqual(
            NotificationManager.bannerBody(for: message(body: "第一行\n\n   \n第二行\n\n")),
            "第一行\n第二行"
        )
    }

    func testSingleLineBodyIsPassedThrough() {
        XCTAssertEqual(NotificationManager.bannerBody(for: message(body: "磁盘已满")), "磁盘已满")
    }

    /// A body of nothing but blank lines has no text to show; it must not become a box of blank rows.
    func testBlankBodyHasNoLinesLeft() {
        XCTAssertEqual(NotificationManager.bannerBody(for: message(body: "\n \n")), "")
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
