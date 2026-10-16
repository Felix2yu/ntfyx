import XCTest
@testable import NtfyxCore

/// The app was renamed to a new bundle identifier, and preferences are stored per identifier —
/// so this is the only thing standing between the rename and a silent loss of the user's
/// per-Mac settings and reconnect watermarks.
final class LegacyPreferenceMigrationTests: XCTestCase {

    private var legacy: UserDefaults!
    private var current: UserDefaults!
    private var suiteNames: [String] = []

    private func openSuites(_ label: String) {
        let legacyName = "ntfyx.migration.\(label).legacy"
        let currentName = "ntfyx.migration.\(label).current"
        suiteNames = [legacyName, currentName]
        legacy = UserDefaults(suiteName: legacyName)
        current = UserDefaults(suiteName: currentName)
    }

    override func tearDown() {
        for (index, suite) in [legacy, current].enumerated() {
            suite?.removePersistentDomain(forName: suiteNames[index])
        }
        legacy = nil
        current = nil
        super.tearDown()
    }

    func testCarriesOverOwnKeysWatermarksAndGeometry() {
        openSuites("carry")
        legacy.set(true, forKey: AppSettings.iCloudSyncEnabledKey)
        legacy.set("~/Sync/ntfyx", forKey: AppSettings.iCloudSyncDirectoryKey)
        legacy.set(17.0, forKey: AppSettings.messageFontSizeKey)
        legacy.set(1_700_000_000, forKey: "lastMessageTime-https://ntfy.sh-1")
        legacy.set(1_700_000_100.0, forKey: AppSettings.lastRetentionRunKey)
        legacy.set("0.000000, 0.000000, 191.000000, 897.000000, NO, NO",
                   forKey: "NSSplitView Subview Frames history-AppWindow-1, SidebarNavigationSplitView")
        // Anything not owned by the app stays behind.
        legacy.set("stale", forKey: "someOtherAppKey")

        AppSettings.migrateLegacyPreferences(from: legacy, into: current)

        XCTAssertTrue(current.bool(forKey: AppSettings.iCloudSyncEnabledKey))
        XCTAssertEqual(current.string(forKey: AppSettings.iCloudSyncDirectoryKey), "~/Sync/ntfyx")
        XCTAssertEqual(current.double(forKey: AppSettings.messageFontSizeKey), 17.0)
        XCTAssertEqual(current.integer(forKey: "lastMessageTime-https://ntfy.sh-1"), 1_700_000_000)
        XCTAssertEqual(current.double(forKey: AppSettings.lastRetentionRunKey), 1_700_000_100.0)
        XCTAssertNotNil(current.string(
            forKey: "NSSplitView Subview Frames history-AppWindow-1, SidebarNavigationSplitView"))
        XCTAssertNil(current.string(forKey: "someOtherAppKey"))
    }

    func testSystemLanguageNeverFollowsTheOldDomain() {
        openSuites("language")
        // `dictionaryRepresentation()` reports the global domain too; writing AppleLanguages
        // into the app's own domain would stop 跟随系统 from ever tracking the system again.
        legacy.set(["en"], forKey: "AppleLanguages")

        AppSettings.migrateLegacyPreferences(from: legacy, into: current)

        // Read the domain's own values, not `object(forKey:)`, which falls through to
        // NSGlobalDomain and would report the machine's real language list here.
        let stored = current.persistentDomain(forName: suiteNames[1]) ?? [:]
        XCTAssertNil(stored["AppleLanguages"])
    }

    func testDoesNotOverwriteWhatTheUserAlreadySetInTheNewDomain() {
        openSuites("wins")
        legacy.set(11.0, forKey: AppSettings.messageFontSizeKey)
        current.set(20.0, forKey: AppSettings.messageFontSizeKey)

        AppSettings.migrateLegacyPreferences(from: legacy, into: current)

        XCTAssertEqual(current.double(forKey: AppSettings.messageFontSizeKey), 20.0)
    }

    func testRunsExactlyOnceEvenIfTheLegacyFileSurvives() {
        openSuites("once")
        legacy.set(13.0, forKey: AppSettings.messageFontSizeKey)
        AppSettings.migrateLegacyPreferences(from: legacy, into: current)

        legacy.set(19.0, forKey: AppSettings.messageFontSizeKey)
        AppSettings.migrateLegacyPreferences(from: legacy, into: current)

        XCTAssertEqual(current.double(forKey: AppSettings.messageFontSizeKey), 13.0,
                       "a second pass would drag in whatever the old domain still holds")
    }

    func testMissingLegacyDomainIsNotAnError() {
        openSuites("absent")
        AppSettings.migrateLegacyPreferences(from: nil, into: current)
        XCTAssertFalse(current.bool(forKey: AppSettings.iCloudSyncEnabledKey))
    }
}
