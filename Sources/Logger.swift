import Foundation

/// Simple logger with timestamps - writes to file (with rotation) and optionally stdout
enum Log {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// Whether running in interactive mode (manual) - only write to stdout in this case
    private static let isInteractiveMode: Bool = {
        isatty(STDOUT_FILENO) != 0
    }()

    /// Log directory
    static let logDirectory: String = {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".local/share/ntfyx/logs").path
    }()

    /// Log file path
    static let logFilePath: String = {
        return (logDirectory as NSString).appendingPathComponent("ntfyx.log")
    }()

    /// Maximum log file size (1 MB)
    private static let maxLogSize: UInt64 = 1_000_000

    // nonisolated(unsafe) needed for Swift 6 concurrency - access is synchronized via synchronize()
    nonisolated(unsafe) private static var fileHandle: FileHandle? = {
        setupLogFile()
    }()

    /// Serializes writes: `FileHandle` is not thread-safe, and neither is `DateFormatter`.
    private static let writeLock = NSLock()

    private static func setupLogFile() -> FileHandle? {
        let fileManager = FileManager.default

        // Create log directory if needed
        do {
            try fileManager.createDirectory(
                atPath: logDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            print("Failed to create log directory: \(error)")
            return nil
        }

        // Rotate log if too large
        rotateLogIfNeeded()

        // Create or open log file
        if !fileManager.fileExists(atPath: logFilePath) {
            fileManager.createFile(atPath: logFilePath, contents: nil, attributes: nil)
        }

        // Open for appending
        guard let handle = FileHandle(forWritingAtPath: logFilePath) else {
            print("Failed to open log file for writing")
            return nil
        }

        handle.seekToEndOfFile()
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

        // Rotate: delete old backup, rename current to .old
        let oldLogPath = logFilePath + ".old"
        try? fileManager.removeItem(atPath: oldLogPath)
        try? fileManager.moveItem(atPath: logFilePath, toPath: oldLogPath)
    }

    private static func log(_ message: String) {
        // Everything below touches shared, non-thread-safe state (the file handle and
        // DateFormatter), and logging happens from the main thread, the URLSession delegate
        // queue and several actors at once.
        writeLock.lock()
        defer { writeLock.unlock() }

        let line = "[\(dateFormatter.string(from: Date()))] \(message)"

        // Only write to stdout in interactive mode (manual run)
        // In service mode, skip stdout to avoid duplicate logs in launchd files
        if isInteractiveMode {
            print(line)
            fflush(stdout)
        }

        // Always write to file (rotated at startup). No fsync per line: a log does not need
        // that durability, and syncing on every line cost the main thread one disk round-trip
        // per notification, which froze the UI during a history replay.
        if let data = (line + "\n").data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    static func info(_ message: String) {
        log(message)
    }

    static func error(_ message: String) {
        log(message)
    }

    static func success(_ message: String) {
        log(message)
    }
}
