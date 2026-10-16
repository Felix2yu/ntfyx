import XCTest
@testable import NtfyxCore

/// Guards the invariant the whole UI rests on: every string the interface asks for has an
/// English translation, and no translation loses a format specifier on the way.
final class LocalizationTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/ntfyxCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
    }

    private static var catalogURL: URL {
        repoRoot.appendingPathComponent("Sources/NtfyxCore/Resources/Localizable.xcstrings")
    }

    // MARK: - Lookup

    func testSourceLanguageReturnsTheKeyItself() {
        XCTAssertEqual(L10n.text("取消", in: .zhHans), "取消")
    }

    func testMissingTranslationFallsBackToChineseInsteadOfAToken() {
        XCTAssertEqual(L10n.text("这条文案没有收录", in: .en), "这条文案没有收录")
    }

    func testEnglishTableIsActuallyLoadedFromTheBundle() {
        XCTAssertTrue(
            L10n.availableLanguages.contains(.en),
            "Localizable.xcstrings did not compile into a usable en table; check Package.swift resources"
        )
    }

    func testFormatUsesTheLiveLanguage() {
        let saved = L10n.language
        defer { L10n.setLanguage(saved) }

        L10n.setLanguage(.en)
        XCTAssertEqual(L10n.format("版本 %@", "1.3.0"), "Version 1.3.0")

        L10n.setLanguage(.zhHans)
        XCTAssertEqual(L10n.format("版本 %@", "1.3.0"), "版本 1.3.0")
    }

    // MARK: - Language choice

    @MainActor
    func testSwitchingChoiceRewritesTextImmediately() {
        let locale = AppLocale.shared
        let saved = locale.choice
        defer {
            locale.choice = saved
            UserDefaults.standard.removeObject(forKey: AppSettings.languageKey)
        }

        locale.choice = .en
        XCTAssertEqual(L("取消"), "Cancel")
        XCTAssertEqual(L10n.language, .en, "background text has to follow the same switch")

        locale.choice = .zhHans
        XCTAssertEqual(L("取消"), "取消")
        XCTAssertEqual(L10n.language, .zhHans)
    }

    @MainActor
    func testChoiceIsPersistedForTheNextLaunch() {
        let locale = AppLocale.shared
        let saved = locale.choice
        defer { locale.choice = saved }

        locale.choice = .en
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppSettings.languageKey), LanguageChoice.en.rawValue)
    }

    func testAutoFollowsTheSystemLanguage() {
        XCTAssertEqual(AppLocale.resolveAuto(systemLanguages: ["en-US", "zh-Hans-CN"]), .en)
        XCTAssertEqual(AppLocale.resolveAuto(systemLanguages: ["zh-Hans-CN"]), .zhHans)
        XCTAssertEqual(AppLocale.resolveAuto(systemLanguages: ["zh-Hant-CN", "en-GB"]), .zhHans)
    }

    func testAutoFallsBackToTheSourceLanguageWhenUnsupported() {
        XCTAssertEqual(AppLocale.resolveAuto(systemLanguages: ["de-DE"]), .zhHans)
        XCTAssertEqual(AppLocale.resolveAuto(systemLanguages: []), .zhHans)
    }

    func testExplicitChoiceIgnoresTheSystem() {
        XCTAssertEqual(LanguageChoice(resolving: "en").fixedLanguage, .en)
        XCTAssertEqual(LanguageChoice(resolving: "zh-Hans").fixedLanguage, .zhHans)
        XCTAssertNil(LanguageChoice(resolving: "auto").fixedLanguage)
        XCTAssertNil(LanguageChoice(resolving: nil).fixedLanguage)
        XCTAssertNil(LanguageChoice(resolving: "nonsense").fixedLanguage)
    }

    // MARK: - Catalog completeness

    func testEveryUITextHasAnEnglishTranslation() throws {
        let catalog = try loadCatalog()
        let used = try localizedCallSites()

        let unrecorded = used.filter { !catalog.keys.contains($0) }.sorted()
        XCTAssertTrue(unrecorded.isEmpty, "L(\"…\") keys missing from the catalog: \(unrecorded)")

        var gaps: [String] = []
        for key in catalog.keys where containsChinese(key) {
            guard let value = catalog[key], !value.isEmpty else {
                gaps.append("\(key) has no English value")
                continue
            }
            if containsChinese(value) {
                gaps.append("\(key) still translates to Chinese: \(value)")
            }
            if specifiers(of: key) != specifiers(of: value) {
                gaps.append(
                    "\(key) → \(value): format specifiers differ "
                        + "(\(specifiers(of: key)) vs \(specifiers(of: value)))"
                )
            }
        }
        XCTAssertTrue(gaps.isEmpty, gaps.joined(separator: "\n"))
    }

    /// The compiled `.strings` inside the resource bundle has to agree with the catalog:
    /// an xcstrings key containing a quote, a newline or a `%` can survive the JSON and still
    /// fail to survive the compiler, which would silently render Chinese in an English UI.
    func testCompiledTableResolvesEveryCatalogKey() throws {
        let catalog = try loadCatalog()
        var drifted: [String] = []
        for (key, expected) in catalog where containsChinese(key) {
            let resolved = L10n.text(key, in: .en)
            if resolved != expected {
                drifted.append("\(key)\n    expected: \(expected)\n    resolved: \(resolved)")
            }
        }
        XCTAssertTrue(drifted.isEmpty, "compiled en table disagrees with the catalog for:\n" + drifted.joined(separator: "\n"))
    }

    func testCatalogKeysAreStillReferenced() throws {
        let used = Set(try localizedCallSites())
        let stale = try loadCatalog().keys.filter { !used.contains($0) }.sorted()
        XCTAssertTrue(stale.isEmpty, "translations no longer used by any call site: \(stale)")
    }

    // MARK: - Helpers

    /// Keys as written in source, with Swift's escapes resolved.
    private func localizedCallSites() throws -> [String] {
        let pattern = #"(?<![A-Za-z0-9_.])(?:L|LF|L10n\.text|L10n\.format)\(\s*"((?:[^"\\\n]|\\.)*)""#
        let regex = try NSRegularExpression(pattern: pattern)
        var keys: [String] = []

        let sources = Self.repoRoot.appendingPathComponent("Sources")
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil
        ) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                files.append(url)
            }
        }

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let stripped = stripComments(text)
            let range = NSRange(stripped.startIndex..., in: stripped)
            for match in regex.matches(in: stripped, range: range) {
                guard let raw = Range(match.range(at: 1), in: stripped) else { continue }
                keys.append(unescapeSwift(String(stripped[raw])))
            }
        }
        return keys
    }

    private func loadCatalog() throws -> [String: String] {
        let data = try Data(contentsOf: Self.catalogURL)
        guard
            let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let strings = doc["strings"] as? [String: Any]
        else { throw CocoaError(.coderReadCorrupt) }

        var table: [String: String] = [:]
        for (key, raw) in strings {
            guard let entry = raw as? [String: Any] else { continue }
            let localizations = entry["localizations"] as? [String: Any]
            let english = localizations?["en"] as? [String: Any]
            let unit = english?["stringUnit"] as? [String: Any]
            table[key] = unit?["value"] as? String ?? ""
        }
        return table
    }

    private func stripComments(_ text: String) -> String {
        var out = text
        while let range = out.range(of: "/*") {
            guard let end = out.range(of: "*/", range: range.upperBound..<out.endIndex) else { break }
            out.removeSubrange(range.lowerBound..<end.upperBound)
        }
        return out
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func unescapeSwift(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\\\", with: "\u{0}")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\u{0}", with: "\\")
    }

    private func containsChinese(_ text: String) -> Bool {
        text.range(
            of: "[\\u3000-\\u303f\\u3400-\\u4dbf\\u4e00-\\u9fff\\uf900-\\ufaff\\uff00-\\uffef]",
            options: .regularExpression
        ) != nil
    }

    /// The conversion characters of every `%`-spec, with `%%` ignored and widths folded away,
    /// so `%ld` and `%d` compare equal while `%@` and `%d` do not.
    private func specifiers(of text: String) -> [Character] {
        var found: [Character] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "%" else {
                index = text.index(after: index)
                continue
            }
            var scan = text.index(after: index)
            if scan < text.endIndex, text[scan] == "%" {
                index = text.index(after: scan)
                continue
            }
            while scan < text.endIndex, "-+ #0123456789$.*".contains(text[scan]) {
                scan = text.index(after: scan)
            }
            while scan < text.endIndex, "hlzqjt".contains(text[scan]) {
                scan = text.index(after: scan)
            }
            guard scan < text.endIndex else { break }
            let conversion = text[scan]
            found.append(
                "diuxXoO".contains(conversion) ? "d" : ("@sp".contains(conversion) ? "@" : conversion)
            )
            index = text.index(after: scan)
        }
        return found
    }
}
