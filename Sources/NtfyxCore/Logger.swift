import Foundation
import OSLog

/// Application logging.
///
/// Two sinks:
/// - `os.Logger` (unified logging): visible in Console.app and via `log stream`, and mirrored
///   to stderr when the process is launched from a terminal.
/// - A rotating file at `~/Library/Logs/ntfyx/ntfyx.log`, which the "查看日志…" menu item
///   reveals in Finder.
public enum Log {
    private static let logger = Logger(
        subsystem: AppConstants.effectiveBundleIdentifier,
        category: "app"
    )

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// Log directory (per-user standard location, also shown by Console.app).
    public static let logDirectory: String = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        return logs.appendingPathComponent("ntfyx", isDirectory: true).path
    }()

    /// Log file path revealed by the "查看日志…" menu item.
    public static let logFilePath: String = {
        (logDirectory as NSString).appendingPathComponent("ntfyx.log")
    }()

    /// Maximum log file size (1 MB); rotation happens once at launch.
    private static let maxLogSize: UInt64 = 1_000_000

    /// Serializes file writes: `FileHandle` is not thread-safe, and neither is `DateFormatter`.
    /// Logging happens from the main thread, the URLSession delegate queue and actors.
    private static let writeLock = NSLock()

    /// Static `let` initializers run atomically, so the handle needs no concurrency annotation.
    private static let fileHandle: FileHandle? = setupLogFile()

    private static func setupLogFile() -> FileHandle? {
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(
                atPath: logDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("Failed to create log directory: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        rotateLogIfNeeded()

        if !fileManager.fileExists(atPath: logFilePath) {
            fileManager.createFile(atPath: logFilePath, contents: nil)
        }

        guard let handle = FileHandle(forWritingAtPath: logFilePath) else {
            logger.error("Failed to open log file for writing")
            return nil
        }

        do {
            try handle.seekToEnd()
        } catch {
            logger.error("Failed to seek log file to end: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return handle
    }

    private static func rotateLogIfNeeded() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: logFilePath),
              let attrs = try? fileManager.attributesOfItem(atPath: logFilePath),
              let size = attrs[.size] as? UInt64,
              size > maxLogSize else {
            return
        }

        let oldLogPath = logFilePath + ".old"
        try? fileManager.removeItem(atPath: oldLogPath)
        try? fileManager.moveItem(atPath: logFilePath, toPath: oldLogPath)
    }

    private static func emit(level: OSLogType, _ message: String) {
        logger.log(level: level, "\(message, privacy: .public)")

        guard let data = ("[\(dateFormatter.string(from: Date()))] \(message)\n")
            .data(using: .utf8) else { return }

        // No fsync per line: a log does not need that durability, and syncing on every line
        // cost the main thread one disk round-trip per notification during history replays.
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try fileHandle?.write(contentsOf: data)
        } catch {
            // A broken log sink must never affect notification delivery; nothing more to do.
        }
    }

    public static func info(_ message: String) {
        emit(level: .info, message)
    }

    public static func error(_ message: String) {
        emit(level: .error, message)
    }

    public static func success(_ message: String) {
        emit(level: .default, message)
    }
}
