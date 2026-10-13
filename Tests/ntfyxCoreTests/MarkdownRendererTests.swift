import XCTest
import SwiftUI
@testable import NtfyxCore

final class MarkdownRendererTests: XCTestCase {

    private func plain(_ attr: AttributedString) -> String {
        String(attr.characters)
    }

    private func firstRun(matching text: String, in attr: AttributedString) -> AttributedString.Runs.Run? {
        attr.runs.first { String(attr[$0.range].characters) == text }
    }

    // MARK: - Line level

    func testHeadings() {
        let out = MarkdownRenderer.render("# Title\n### Small")
        XCTAssertEqual(plain(out), "Title\nSmall")
        XCTAssertEqual(firstRun(matching: "Title", in: out)?.font, Font.system(size: 17, weight: .bold))
        XCTAssertEqual(firstRun(matching: "Small", in: out)?.font, Font.system(size: 14, weight: .bold))
    }

    func testUnorderedList() {
        XCTAssertEqual(plain(MarkdownRenderer.render("- one\n* two\n+ three")), "• one\n• two\n• three")
    }

    func testOrderedList() {
        XCTAssertEqual(plain(MarkdownRenderer.render("3. third")), "3. third")
    }

    func testBlockquote() {
        XCTAssertEqual(plain(MarkdownRenderer.render("> quoted")), "▏quoted")
    }

    func testHorizontalRule() {
        XCTAssertEqual(plain(MarkdownRenderer.render("---")), "───────")
    }

    func testFencedCodeBlock() {
        let out = MarkdownRenderer.render("```swift\nlet x = 1\n```")
        XCTAssertEqual(plain(out), "let x = 1")
        XCTAssertEqual(firstRun(matching: "let x = 1", in: out)?.font, Font.system(size: 12, design: .monospaced))
    }

    func testNewlinesBetweenLinesAreKept() {
        XCTAssertEqual(plain(MarkdownRenderer.render("line1\nline2")), "line1\nline2")
    }

    // MARK: - Inline level

    func testBold() {
        let out = MarkdownRenderer.render("Hello **world** again")
        XCTAssertEqual(plain(out), "Hello world again")
        let bold = firstRun(matching: "world", in: out)
        XCTAssertEqual(bold?.font, Font.system(size: 13).bold())
        XCTAssertEqual(bold?.inlinePresentationIntent, .stronglyEmphasized)
    }

    func testItalic() {
        let out = MarkdownRenderer.render("say *hi* now")
        let italic = firstRun(matching: "hi", in: out)
        XCTAssertEqual(italic?.font, Font.system(size: 13).italic())
        XCTAssertEqual(italic?.inlinePresentationIntent, .emphasized)
    }

    func testCodeSpan() {
        let out = MarkdownRenderer.render("run `make test` now")
        let code = firstRun(matching: "make test", in: out)
        XCTAssertEqual(code?.font, Font.system(size: 12, design: .monospaced))
        XCTAssertNotNil(code?.backgroundColor)
    }

    func testStrikethrough() {
        let out = MarkdownRenderer.render("~~gone~~")
        XCTAssertNotNil(firstRun(matching: "gone", in: out)?.strikethroughStyle)
    }

    func testLink() {
        let out = MarkdownRenderer.render("see [Qoder](https://qoder.com) for more")
        let link = firstRun(matching: "Qoder", in: out)
        XCTAssertEqual(link?.link, URL(string: "https://qoder.com"))
    }

    func testImageShowsAltText() {
        XCTAssertEqual(plain(MarkdownRenderer.render("![cat](https://x/i.png)")), "🖼 cat")
    }

    func testCustomFontSizeScalesEverything() {
        let out = MarkdownRenderer.render("# H\n`c`\ntext **b**", fontSize: 16)
        XCTAssertEqual(firstRun(matching: "H", in: out)?.font, Font.system(size: 20, weight: .bold))
        XCTAssertEqual(firstRun(matching: "c", in: out)?.font, Font.system(size: 15, design: .monospaced))
        XCTAssertEqual(firstRun(matching: "b", in: out)?.font, Font.system(size: 16).bold())
    }

    func testBoldInsideListItem() {
        let out = MarkdownRenderer.render("- **ship** it")
        XCTAssertEqual(plain(out), "• ship it")
        XCTAssertEqual(firstRun(matching: "ship", in: out)?.inlinePresentationIntent, .stronglyEmphasized)
    }
}
