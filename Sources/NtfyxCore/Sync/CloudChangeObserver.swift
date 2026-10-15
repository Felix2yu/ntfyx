import Foundation

/// One cloud-side observation: the shared file (or an unresolved conflict version of it)
/// may have changed since the last merge pass.
public struct CloudChange: Sendable, Equatable {
    /// Unresolved conflict version URLs at the moment the event fired; may be empty.
    public var conflictURLs: [URL]
}

/// Watches the sync folder and emits one value per *settled* cloud-side change.
///
/// There is deliberately no timer in here (E2b replaces the 60 s OS activity):
/// - in iCloud Drive an `NSMetadataQuery` reports both content updates and placeholder
///   download progress, so a not-yet-downloaded file triggers `startDownloading…` and
///   the *next* metadata update drives the merge;
/// - for a custom folder (and as the fallback when the metadata query cannot start on
///   this machine) a `DispatchSource` on the directory catches FileProvider materialising
///   bytes or any other process rewriting the file.
///
/// Bursts of notifications (a download reports several progress updates) are coalesced
/// behind one debounce on an internal serial queue.
public final class CloudChangeObserver: @unchecked Sendable {
    /// Backing watch mechanism. Kept as a seam so tests never touch a real query/kqueue.
    protocol Source: AnyObject, Sendable {
        /// Starts watching; `false` means "I cannot run here" and the observer falls back.
        func start(onEvent: @escaping @Sendable () -> Void) -> Bool
        func stop()
    }

    nonisolated let changes: AsyncStream<CloudChange>
    private let continuation: AsyncStream<CloudChange>.Continuation

    private let queue = DispatchQueue(label: "com.ntfyx.cloud-change-observer")
    private let isICloud: Bool
    private let debounceInterval: TimeInterval
    private let conflictURLs: @Sendable () -> [URL]
    private let makePrimary: () -> Source
    private let makeFallback: () -> Source

    private var source: Source?
    private var usingFallback = false
    private var isRunning = false
    private var pending: DispatchWorkItem?

    /// Production initializer: metadata query in iCloud Drive, directory kqueue otherwise
    /// (and as the iCloud fallback).
    public convenience init(rootDirectory: String, isICloud: Bool, debounceInterval: TimeInterval = 2) {
        let root = URL(fileURLWithPath: rootDirectory)
        let fileURL = root.appendingPathComponent(CloudConfigStore.fileName)
        self.init(
            rootDirectory: rootDirectory,
            isICloud: isICloud,
            debounceInterval: debounceInterval,
            conflictURLs: {
                (NSFileVersion.unresolvedConflictVersionsOfItem(at: fileURL) ?? []).map(\.url)
            },
            makePrimary: {
                MetadataQueryCloudSource(directoryURL: root, fileName: CloudConfigStore.fileName)
            },
            makeFallback: {
                DispatchSourceCloudSource(directoryURL: root)
            }
        )
    }

    /// Seam-rich initializer used by tests.
    init(
        rootDirectory: String,
        isICloud: Bool,
        debounceInterval: TimeInterval = 2,
        conflictURLs: @escaping @Sendable () -> [URL],
        makePrimary: @escaping () -> Source,
        makeFallback: @escaping () -> Source
    ) {
        self.isICloud = isICloud
        self.debounceInterval = debounceInterval
        self.conflictURLs = conflictURLs
        self.makePrimary = makePrimary
        self.makeFallback = makeFallback

        var continuation: AsyncStream<CloudChange>.Continuation!
        changes = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation = $0 }
        self.continuation = continuation
    }

    deinit {
        pending?.cancel()
        source?.stop()
        continuation.finish()
    }

    func start() {
        queue.sync {
            guard !isRunning else { return }
            isRunning = true

            let handler: @Sendable () -> Void = { [weak self] in
                self?.scheduleCoalesced()
            }

            if isICloud {
                let primary = makePrimary()
                if primary.start(onEvent: handler) {
                    source = primary
                    Log.info("云端变更观察已启动（NSMetadataQuery）")
                    return
                }
                primary.stop()
                Log.info("NSMetadataQuery 不可用，云端变更观察降级为目录事件源")
            }

            let fallback = makeFallback()
            if fallback.start(onEvent: handler) {
                source = fallback
                usingFallback = true
                Log.info("云端变更观察已启动（目录事件源\(isICloud ? "，降级模式" : "")）")
            } else {
                // No usable source at all: the first-launch merge and manual "立即同步"
                // remain the safety net; no timer is introduced to paper over this.
                Log.error("云端变更观察无法启动：\(rootDirectoryDescription)")
            }
        }
    }

    func stop() {
        queue.sync {
            isRunning = false
            pending?.cancel()
            pending = nil
            source?.stop()
            source = nil
            usingFallback = false
        }
    }

    private var rootDirectoryDescription: String {
        // Only used for diagnostics; the URL itself is captured by the source factories.
        isICloud ? "iCloud Drive 目录" : "自定义同步目录"
    }

    private func scheduleCoalesced() {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.emit() }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: work)
        }
    }

    private func emit() {
        let urls = conflictURLs().sorted { $0.path < $1.path }
        continuation.yield(CloudChange(conflictURLs: urls))
    }
}

// MARK: - NSMetadataQuery source

/// The slice of `NSMetadataQuery` the source depends on (faked in tests).
protocol MetadataQuerying: AnyObject {
    var searchScopes: [Any] { get set }
    var predicate: NSPredicate? { get set }
    func startQuery() -> Bool
    func stopQuery()
    func disableUpdates()
    func enableUpdates()
    var resultURLs: [URL] { get }
}

final class RealMetadataQuery: MetadataQuerying {
    private let query = NSMetadataQuery()

    var searchScopes: [Any] {
        get { query.searchScopes }
        set { query.searchScopes = newValue }
    }
    var predicate: NSPredicate? {
        get { query.predicate }
        set { query.predicate = newValue }
    }

    func startQuery() -> Bool { query.start() }
    func stopQuery() { query.stop() }
    func disableUpdates() { query.disableUpdates() }
    func enableUpdates() { query.enableUpdates() }

    var resultURLs: [URL] {
        query.results.compactMap { item in
            (item as? NSMetadataItem)?.value(forAttribute: NSMetadataItemURLKey) as? URL
        }
    }
}

/// Whether the shared file is safe to merge right now. `nil` download status (a plain
/// local file) counts as ready — the metadata source may also watch a non-evicted copy.
enum CloudFileReadiness: Equatable, Sendable {
    case ready
    case needsDownload
}

/// Observes the shared file through iCloud metadata: download status gates events so a
/// merge never runs against an evicted placeholder, and a not-current placeholder kicks
/// off a download whose completion arrives as the next metadata update — no polling.
final class MetadataQueryCloudSource: NSObject, CloudChangeObserver.Source, @unchecked Sendable {
    private let directoryURL: URL
    private let fileName: String
    private let notificationCenter: NotificationCenter
    private let makeQuery: () -> MetadataQuerying
    private let readiness: @Sendable (URL) -> CloudFileReadiness
    private let startDownload: @Sendable (URL) -> Void

    private let queue = DispatchQueue(label: "com.ntfyx.metadata-query-source")
    private var query: MetadataQuerying?
    private var observerTokens: [NSObjectProtocol] = []
    private var onEvent: (@Sendable () -> Void)?

    init(
        directoryURL: URL,
        fileName: String,
        notificationCenter: NotificationCenter = .default,
        makeQuery: @escaping () -> MetadataQuerying = { RealMetadataQuery() },
        readiness: @escaping @Sendable (URL) -> CloudFileReadiness = MetadataQueryCloudSource.defaultReadiness,
        startDownload: @escaping @Sendable (URL) -> Void = { url in
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    ) {
        self.directoryURL = directoryURL
        self.fileName = fileName
        self.notificationCenter = notificationCenter
        self.makeQuery = makeQuery
        self.readiness = readiness
        self.startDownload = startDownload
        super.init()
    }

    static func defaultReadiness(_ url: URL) -> CloudFileReadiness {
        guard let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus else {
            return .ready
        }
        return status == .current ? .ready : .needsDownload
    }

    func start(onEvent: @escaping @Sendable () -> Void) -> Bool {
        queue.sync {
            let candidate = makeQuery()
            candidate.searchScopes = [directoryURL]
            candidate.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, fileName)

            let center = notificationCenter
            let note: @Sendable (Notification) -> Void = { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.evaluate() }
            }
            observerTokens = [
                center.addObserver(forName: Notification.Name.NSMetadataQueryDidFinishGathering, object: candidate, queue: nil, using: note),
                center.addObserver(forName: Notification.Name.NSMetadataQueryDidUpdate, object: candidate, queue: nil, using: note),
            ]

            guard candidate.startQuery() else {
                observerTokens.forEach { center.removeObserver($0) }
                observerTokens = []
                candidate.stopQuery()
                return false
            }
            query = candidate
            self.onEvent = onEvent
            return true
        }
    }

    func stop() {
        queue.sync {
            observerTokens.forEach { notificationCenter.removeObserver($0) }
            observerTokens = []
            query?.stopQuery()
            query = nil
            onEvent = nil
        }
    }

    private func evaluate() {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        let scopePath = directoryURL.standardizedFileURL.path
        guard let fileURL = query.resultURLs.first(where: {
            $0.lastPathComponent == fileName
                // Compare path strings: a URL derived via `deletingLastPathComponent`
                // keeps a trailing-slash/directory flag that makes URL `==` fail.
                && $0.deletingLastPathComponent().standardizedFileURL.path == scopePath
        }) else {
            // The file has not appeared in the ubiquitous index yet; nothing to merge.
            return
        }

        switch readiness(fileURL) {
        case .ready:
            // A regular local file or a fully downloaded placeholder.
            onEvent?()
        case .needsDownload:
            // Ask iCloud for the bytes; the resulting update re-enters this method.
            startDownload(fileURL)
        }
    }
}

// MARK: - DispatchSource (directory kqueue) source

/// Minimal slice of the directory kqueue source (faked in tests).
protocol FileSystemEventSourcing: AnyObject, Sendable {
    func install(handler: @escaping @Sendable () -> Void)
    func installCancelHandler(_ handler: @escaping @Sendable () -> Void)
    func resume()
    func cancel()
}

/// Production wrapper around a real `DispatchSourceFileSystemObject`.
final class DispatchFileSystemSource: FileSystemEventSourcing, @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject

    init(fileDescriptor: CInt) {
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: nil
        )
    }

    func install(handler: @escaping @Sendable () -> Void) { source.setEventHandler(handler: handler) }
    func installCancelHandler(_ handler: @escaping @Sendable () -> Void) { source.setCancelHandler(handler: handler) }
    func resume() { source.resume() }
    func cancel() { source.cancel() }
}

/// Watches the directory itself (write/rename/delete/extend): FileProvider materialising a
/// download and a plain atomic rewrite both produce these events.
final class DispatchSourceCloudSource: CloudChangeObserver.Source, @unchecked Sendable {
    private let directoryURL: URL
    private let makeSource: @Sendable (CInt) -> FileSystemEventSourcing?
    private let openDirectory: @Sendable (String) -> CInt

    private let queue = DispatchQueue(label: "com.ntfyx.dispatch-source-cloud")
    private var source: FileSystemEventSourcing?
    private var fileDescriptor: CInt = -1
    private var onEvent: (@Sendable () -> Void)?

    init(
        directoryURL: URL,
        makeSource: @escaping @Sendable (CInt) -> FileSystemEventSourcing? = DispatchSourceCloudSource.defaultMakeSource,
        openDirectory: @escaping @Sendable (String) -> CInt = { Darwin.open($0, O_EVTONLY) }
    ) {
        self.directoryURL = directoryURL
        self.makeSource = makeSource
        self.openDirectory = openDirectory
    }

    static func defaultMakeSource(fileDescriptor: CInt) -> FileSystemEventSourcing? {
        DispatchFileSystemSource(fileDescriptor: fileDescriptor)
    }

    func start(onEvent: @escaping @Sendable () -> Void) -> Bool {
        queue.sync {
            let fd = openDirectory(directoryURL.path)
            guard fd >= 0 else { return false }
            guard let made = makeSource(fd) else {
                Darwin.close(fd)
                return false
            }

            made.installCancelHandler { Darwin.close(fd) }
            made.install { [weak self] in
                guard let self else { return }
                self.queue.async { self.onEvent?() }
            }
            made.resume()

            fileDescriptor = fd
            source = made
            self.onEvent = onEvent
            return true
        }
    }

    func stop() {
        queue.sync {
            // Cancelling closes the descriptor through the cancel handler.
            source?.cancel()
            source = nil
            fileDescriptor = -1
            onEvent = nil
        }
    }

    /// Test/teardown hook for the real source only.
    var isRunningForTesting: Bool {
        queue.sync { source != nil }
    }
}
