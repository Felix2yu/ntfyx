import Foundation

/// UserDefaults keys for app-level (non-config-file) settings.
public enum AppSettings {
    static let expandMessagesByDefaultKey = "historyExpandMessagesByDefault"
    static let scrollMarksReadKey = "historyScrollMarksRead"
    static let messageFontSizeKey = "historyMessageFontSize"
    static let historySidebarWidthKey = "historySidebarWidth"
    static let languageKey = "uiLanguage"
    static let lastRetentionRunKey = "historyLastRetentionRun"
    public static let iCloudSyncEnabledKey = "icloudSyncEnabled"
    public static let iCloudSyncDirectoryKey = "icloudSyncDirectory"

    /// One `lastMessageTime-<serverURL>-<fetchMissed>` per connected server: the reconnect
    /// watermark that decides whether the server's cache is catch-up or live traffic.
    static let watermarkKeyPrefix = "lastMessageTime-"

    /// Window and sidebar geometry AppKit stores on our behalf. The identifiers inside these
    /// keys carry no bundle prefix, so the new build reads them back as-is.
    private static let geometryKeyPrefixes = ["NSWindow Frame ", "NSSplitView Subview Frames "]

    private static let ownedKeys = [
        expandMessagesByDefaultKey, scrollMarksReadKey, messageFontSizeKey,
        historySidebarWidthKey, iCloudSyncEnabledKey, iCloudSyncDirectoryKey,
        lastRetentionRunKey,
    ]

    private static let legacyMigratedKey = "migratedLegacyPreferences"

    /// Preferences are stored per bundle identifier, so renaming the app would silently drop
    /// every one of them on existing installs: the iCloud switch and folder, the history font,
    /// the window layout, the retention schedule, and each server's reconnect watermark —
    /// losing that makes the next connect replay the whole cache. Folded in once, and only
    /// where the new domain has nothing yet, so a value the user already set wins.
    ///
    /// Selection is a whitelist rather than a copy of the old file because
    /// `dictionaryRepresentation()` also reports the global domain; `AppleLanguages` in
    /// particular must never follow, or the interface language would stop tracking the system.
    public static func migrateLegacyPreferences(
        from legacy: UserDefaults? = UserDefaults(suiteName: AppConstants.legacyBundleIdentifier),
        into defaults: UserDefaults = .standard
    ) {
        if defaults.bool(forKey: legacyMigratedKey) { return }
        defer { defaults.set(true, forKey: legacyMigratedKey) }
        guard let legacy else { return }

        let prefixes = [watermarkKeyPrefix] + geometryKeyPrefixes
        for key in legacy.dictionaryRepresentation().keys
        where ownedKeys.contains(key) || prefixes.contains(where: { key.hasPrefix($0) }) {
            guard defaults.object(forKey: key) == nil, let value = legacy.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
        }
    }
}
