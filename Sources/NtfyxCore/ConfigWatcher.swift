import Foundation

/// Watches the *directory* containing the config file (audit E3), with a second source
/// on the file itself for in-place edits.
///
/// Why two sources: editors and cloud agents usually save atomically
/// (`write(tmp); rename(tmp, config.yml)`), which replaces the directory entry but
/// leaves any old file-inode source dead — watching only the file used to require a
/// guessed 0.5 s re-arm race, and could not be installed while the file was missing.
/// Watching the parent directory's `.write` event survives atomic replacement and
/// file (re)creation; the file source additionally catches non-atomic in-place writes
/// (`cat > config.yml`, appends) that never touch the directory entry.
///
/// All file-descriptor and dispatch-source state is main-actor isolated: both sources
/// target `DispatchQueue.main`, and the owner (`ConfigStore`) is `@MainActor`.
/// Event bursts (a save routinely produces rename + entry events) coalesce into one
/// callback per 0.25 s quiet window.
@MainActor
final class ConfigWatcher {
    /// Directory-entry changes: create/delete/rename of the config file.
    private var directoryFD: Int32 = -1
    private var directorySource: DispatchSourceFileSystemObject?

    /// Content changes of the current file inode (in-place writes that never rename).
    private var fileFD: Int32 = -1
    private var fileSource: DispatchSourceFileSystemObject?
    private var watchedFileID: NSNumber?

    private let targetPath: String
    private let directoryPath: String
    private var onChange: (() -> Void)?
    private var settleTask: Task<Void, Never>?
    private var installRetryTask: Task<Void, Never>?

    /// Quiet window after the first event of a burst before the single callback fires.
    static let settleInterval: TimeInterval = 0.25
    /// One retry when the directory cannot be opened yet (created just before launch).
    static let installRetryDelay: TimeInterval = 0.5

    init(configPath: String? = nil) {
        self.targetPath = configPath ?? ConfigFile.defaultConfigPath
        self.directoryPath = URL(fileURLWithPath: targetPath).deletingLastPathComponent().path
    }

    /// Starts watching. The callback fires on the main actor after each settled change
    /// burst; filtering ("is this actually our file, and did the bytes change?") is the
    /// owner's job.
    func startWatching(onChange: @escaping () -> Void) {
        self.onChange = onChange
        installDirectorySource()
        refreshFileSource()
        Log.info("Watching config directory for changes: \(directoryPath)")
    }

    /// Stops watching and cancels every pending task/source.
    func stopWatching() {
        installRetryTask?.cancel()
        installRetryTask = nil
        settleTask?.cancel()
        settleTask = nil
        fileSource?.cancel()
        fileSource = nil
        watchedFileID = nil
        directorySource?.cancel()
        directorySource = nil
    }

    // MARK: - Sources

    private func installDirectorySource() {
        // First launch may create the directory a moment before installing the watcher.
        if !FileManager.default.fileExists(atPath: directoryPath) {
            try? FileManager.default.createDirectory(
                atPath: directoryPath, withIntermediateDirectories: true
            )
        }

        let fd = open(directoryPath, O_EVTONLY)
        guard fd >= 0 else {
            Log.error("Could not watch config directory for changes: \(directoryPath)")
            scheduleInstallRetry()
            return
        }
        directoryFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleSettle()
            }
        }
        source.setCancelHandler { [weak self] in
            // Exactly this generation's descriptor; never an instance property a newer
            // source may have replaced meanwhile.
            close(fd)
            MainActor.assumeIsolated {
                if self?.directoryFD == fd { self?.directoryFD = -1 }
            }
        }
        directorySource = source
        source.resume()
    }

    /// (Re)opens the file source when the target's inode differs from the one currently
    /// watched, and tears it down when the file is gone. Called at install and after
    /// every settled directory event.
    private func refreshFileSource() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: targetPath)
        let fileID = attributes?[.systemFileNumber] as? NSNumber

        guard fileID != watchedFileID else { return }

        fileSource?.cancel()
        fileSource = nil
        watchedFileID = fileID

        guard let fileID else { return }

        let fd = open(targetPath, O_EVTONLY)
        guard fd >= 0 else {
            Log.error("Could not watch config file for in-place changes: \(targetPath)")
            return
        }
        self.fileFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduleSettle()
            }
        }
        source.setCancelHandler { [weak self, fd, fileID] in
            // Exactly this generation's descriptor; a newer replacement source owns a
            // different fd and must not be touched here.
            close(fd)
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.watchedFileID == fileID {
                    self.fileFD = -1
                    self.watchedFileID = nil
                }
            }
        }
        fileSource = source
        source.resume()
    }

    private func scheduleInstallRetry() {
        installRetryTask?.cancel()
        installRetryTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.installRetryDelay * 1_000_000_000)
            )
            guard !Task.isCancelled, let self else { return }
            guard self.directorySource == nil else { return }
            self.installDirectorySource()
            self.refreshFileSource()
        }
    }

    // MARK: - Coalescing

    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.settleInterval * 1_000_000_000)
            )
            guard !Task.isCancelled, let self else { return }
            // The directory may now point at a brand-new inode (atomic save).
            self.refreshFileSource()
            self.onChange?()
        }
    }

    deinit {
        // The cancel handlers close the descriptors.
        directorySource?.cancel()
        fileSource?.cancel()
    }
}
