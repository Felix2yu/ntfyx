import Foundation

/// Parses the HTTP `Retry-After` header (RFC 9110): the value is either a number of
/// delta-seconds or an HTTP-date. Single implementation shared by the SSE transport and
/// the history poll client (audit C4 — the two copies used to drift).
enum HTTPRetryAfter {
    /// Minimum delay applied to zero/negative values and past dates.
    static let minimumDelay: TimeInterval = 1.0
    /// Used when the header is present but unparseable.
    static let fallbackDelay: TimeInterval = 30.0

    static func delay(forHeaderValue value: String, now: Date = Date()) -> TimeInterval {
        // Delta-seconds first. Note that leading/trailing whitespace is not a valid
        // delta-seconds value, so it deliberately falls through to the date parser and
        // then the fallback (locked in by RetryAfterTests).
        if let seconds = TimeInterval(value) {
            return max(seconds, minimumDelay)
        }

        // HTTP-date (e.g. "Sun, 18 Jan 2026 23:59:59 GMT").
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",  // IMF-fixdate
            "EEEE, dd-MMM-yy HH:mm:ss zzz",   // RFC 850
            "EEE MMM d HH:mm:ss yyyy",        // ANSI C asctime()
        ]
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return max(date.timeIntervalSince(now), minimumDelay)
            }
        }

        return fallbackDelay
    }
}
