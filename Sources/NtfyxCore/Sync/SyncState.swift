import Foundation

/// What one Mac remembers about the shared configuration between launches: the state every
/// device last agreed on (the merge ancestor). Cloud-side movement is delivered by
/// `CloudChangeObserver` events, so no poll fingerprint is kept anymore (E2b).
public struct SyncState: Codable, Equatable, Sendable {
    public var base: SyncDocument?
    public var lastSyncedAt: Date?
}

/// Sync timestamps follow the interface language: the templates are translation keys and the
/// formatter's locale comes from the same language, so 年月日 and "Oct 4" never mix.
public enum SyncTimeFormat {
    private static var formatter: DateFormatter { make(L10n.text("yyyy年M月d日 HH:mm")) }
    private static var timeFormatter: DateFormatter { make("HH:mm") }
    private static var monthDayFormatter: DateFormatter { make(L10n.text("M月d日 HH:mm")) }

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.language.localeIdentifier)
        formatter.dateFormat = format
        return formatter
    }

    public static func string(_ date: Date) -> String {
        formatter.string(from: date)
    }

    /// Short enough not to widen the menu bar menu: the year is implied for recent syncs and
    /// the clock is implied for today. Callers keep `string(_:)` for the full timestamp.
    public static func compactString(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return timeFormatter.string(from: date)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return monthDayFormatter.string(from: date)
        }
        return formatter.string(from: date)
    }
}

/// `~/Library/Application Support/ntfyx/sync-state.json`, next to the history database.
public enum SyncStateStore {
    static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("ntfyx", isDirectory: true)
            .appendingPathComponent("sync-state.json")
    }

    public static func load() -> SyncState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(SyncState.self, from: data) else {
            return SyncState(base: nil, lastSyncedAt: nil)
        }
        return state
    }

    public static func save(_ state: SyncState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
