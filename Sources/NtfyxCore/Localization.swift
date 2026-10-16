import Foundation
import Observation

/// The languages the GUI ships tables for. `rawValue` is the `.lproj` name, so it has to
/// match the localizations in `Resources/Localizable.xcstrings`.
public enum UiLanguage: String, CaseIterable, Sendable, Equatable {
    case zhHans = "zh-Hans"
    case en

    /// Locale for date and time formatting. Month and weekday names have to agree with the
    /// language of the text around them, not with the user's system region.
    public var localeIdentifier: String {
        switch self {
        case .zhHans: "zh_CN"
        case .en: "en_US"
        }
    }
}

/// What the user picked under 设置 → 通用 → 界面语言.
public enum LanguageChoice: String, CaseIterable, Identifiable, Sendable, Equatable {
    case auto
    case zhHans = "zh-Hans"
    case en

    public var id: String { rawValue }

    init(resolving raw: String?) {
        guard let raw, raw != LanguageChoice.auto.rawValue, let choice = LanguageChoice(rawValue: raw) else {
            self = .auto
            return
        }
        self = choice
    }

    /// `nil` when the choice follows the system.
    var fixedLanguage: UiLanguage? {
        switch self {
        case .auto: return nil
        case .zhHans: return .zhHans
        case .en: return .en
        }
    }
}

/// Translation lookup for user-facing text. Keys *are* the Chinese source text, so a
/// missing translation degrades to the original wording instead of leaking a token like
/// `settings.cancel` into the interface.
public enum L10n {
    /// The language the source is written in; every fallback ends up here.
    public static let sourceLanguage: UiLanguage = .zhHans

    private static let lock = NSLock()
    // Every read and write goes through `lock`, which is what makes opting these two out of
    // strict-concurrency checking sound.
    nonisolated(unsafe) private static var live: UiLanguage = L10n.sourceLanguage
    nonisolated(unsafe) private static var tableBundles: [UiLanguage: Bundle?] = [:]

    /// The language background code (banners, the Dock badge) renders in. Kept in step with
    /// `AppLocale.language`, which the UI reads instead.
    public static var language: UiLanguage {
        lock.withLock { live }
    }

    static func setLanguage(_ language: UiLanguage) {
        lock.withLock { live = language }
    }

    /// `key` in the live language, or in `language` when the caller already knows it (tests).
    public static func text(_ key: String, in language: UiLanguage? = nil) -> String {
        let target = language ?? lock.withLock { live }
        guard target != sourceLanguage, let bundle = table(for: target) else { return key }
        let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
        return value == key || value.isEmpty ? key : value
    }

    /// `%d`/`%@` substitution on top of `text`.
    public static func format(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }

    /// The compiled strings live in the module's resource bundle, one `.lproj` per language.
    private static func table(for language: UiLanguage) -> Bundle? {
        lock.withLock {
            if let cached = tableBundles[language] { return cached }
            let url = Bundle.module.url(forResource: language.rawValue, withExtension: "lproj")
            let bundle = url.flatMap { Bundle(url: $0) }
            tableBundles[language] = bundle
            return bundle
        }
    }

    /// Languages the built bundle actually carries a table for. Empty when running outside an
    /// app bundle (a bare `swift run` has no resources next to the binary).
    public static var availableLanguages: [UiLanguage] {
        UiLanguage.allCases.filter { table(for: $0) != nil }
    }
}

/// Owns the GUI language choice and keeps `L10n` in step with it.
///
/// Views reach it through `L`/`LF`, which read `language`; that is what makes a switch
/// repaint the interface immediately instead of waiting for a relaunch.
@MainActor
@Observable
public final class AppLocale {
    public static let shared = AppLocale()

    public var choice: LanguageChoice {
        didSet {
            guard choice != oldValue else { return }
            UserDefaults.standard.set(choice.rawValue, forKey: AppSettings.languageKey)
            apply()
        }
    }

    /// Rebuilds language-dependent state the SwiftUI tree does not own — notification
    /// action categories, for instance. Installed by the app's composition root.
    @ObservationIgnored public var onLanguageChange: (() -> Void)?

    /// The language `L` resolves against. Computed from `choice`, so reading it also records
    /// the observation dependency on `choice`.
    public var language: UiLanguage {
        choice.fixedLanguage ?? Self.autoLanguage
    }

    /// `NTFYX_UI_LANGUAGE` forces the auto-resolved language (used to drive the English UI
    /// from a script); an explicit choice in the settings window still wins over it.
    public static var forcedLanguageOverride: UiLanguage? {
        guard let raw = ProcessInfo.processInfo.environment["NTFYX_UI_LANGUAGE"] else { return nil }
        return UiLanguage(rawValue: raw)
    }

    private static var autoLanguage: UiLanguage {
        if let forced = forcedLanguageOverride { return forced }
        return resolveAuto(systemLanguages: preferredSystemLanguages)
    }

    /// `AppleLanguages` as the process sees it: the system list, with the per-app override
    /// from 系统设置 → 通用 → 语言与地区 → 应用程序 already folded in.
    ///
    /// A bare `swift run`/`swift test` binary is not a localized bundle, so it deliberately
    /// reports no preference and the UI stays in the source language — that is also what
    /// keeps the suite's Chinese expectations green on an English CI runner.
    public static var preferredSystemLanguages: [String] {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return [] }
        return UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
    }

    nonisolated static func resolveAuto(systemLanguages: [String]) -> UiLanguage {
        for code in systemLanguages {
            // "zh-Hans-CN" / "en-US" → the bare subtag the tables are named by.
            let base = String(code.prefix(while: { $0 != "-" }))
            if base == UiLanguage.en.rawValue { return .en }
            if base.hasPrefix("zh") { return .zhHans }
        }
        return .zhHans
    }

    private init() {
        choice = LanguageChoice(resolving: UserDefaults.standard.string(forKey: AppSettings.languageKey))
        apply()
    }

    private func apply() {
        L10n.setLanguage(language)
        onLanguageChange?()
    }
}

/// User-facing text in the live language. `key` is the Chinese source string.
@MainActor
public func L(_ key: String) -> String {
    L10n.text(key, in: AppLocale.shared.language)
}

/// `L` with substitutions: `LF("%d 个主题", count)`.
@MainActor
public func LF(_ key: String, _ arguments: any CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}
