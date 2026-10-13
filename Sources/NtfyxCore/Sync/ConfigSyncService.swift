import Foundation
import Observation

/// Keeps this Mac's configuration file and the shared iCloud Drive file in step: local
/// edits are merged into the cloud copy, cloud edits are merged into the local file, and
/// the app's own config reload picks the result up. Messages are deliberately not part of
/// this — the history is fetched from the ntfy server, which already tracks read and
/// deleted state across devices.
///
/// This facade is the MainActor-visible surface (SwiftUI settings, menu bar); every merge
/// pass runs in `ConfigSyncCoordinator` off the main actor (audit E1). Status arrives over
/// an `AsyncStream` and is assigned to the observable `status` property here.
@MainActor
@Observable
public final class ConfigSyncService {
    public static let shared = ConfigSyncService()

    public enum Status: Equatable, Sendable {
        case off
        case waiting
        case syncing
        case synced(Date)
        case failed(String)
    }

    private(set) public var status: Status = .off

    /// Repeating OS activity that polls the cloud copy (audit F3). The system scheduler's
    /// floor is 60 s, so the former 45 s in-process sleep loop retires; the system adds
    /// energy-aware coalescing on top.
    private static let pollActivityInterval: TimeInterval = 60
    private static let pollActivityTolerance: TimeInterval = 15

    private let coordinator: ConfigSyncCoordinator
    private let backgroundTasks: BackgroundTasks
    private var statusTask: Task<Void, Never>?

    public init(
        configStore: ConfigStore = .shared,
        backgroundTasks: BackgroundTasks = .shared
    ) {
        self.backgroundTasks = backgroundTasks
        let snapshot: @Sendable @MainActor () -> ConfigSyncCoordinator.LocalSnapshot = {
            ConfigSyncCoordinator.LocalSnapshot(
                config: configStore.config,
                isDefaultPath: configStore.activePath == nil
                    || configStore.activePath == ConfigStore.defaultConfigPath
            )
        }
        coordinator = ConfigSyncCoordinator(localSnapshot: snapshot)
        let stream = coordinator.status
        statusTask = Task { [weak self] in
            for await newStatus in stream {
                self?.status = newStatus
            }
        }
    }

    // MARK: - Settings

    public var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppSettings.iCloudSyncEnabledKey)
    }

    /// Custom sync folder; empty means iCloud Drive.
    var directoryOverride: String {
        UserDefaults.standard.string(forKey: AppSettings.iCloudSyncDirectoryKey) ?? ""
    }

    var syncDirectory: String {
        CloudConfigStore(
            directoryOverride: directoryOverride.isEmpty ? nil : directoryOverride
        ).rootDirectory
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        UserDefaults.standard.set(enabled, forKey: AppSettings.iCloudSyncEnabledKey)
        if enabled {
            registerPollActivity()
            Task { await coordinator.start() }
        } else {
            unregisterPollActivity()
            Task { await coordinator.stop() }
            status = .off
            Log.info("配置同步已关闭")
        }
    }

    func setDirectory(_ path: String) {
        guard path != directoryOverride else { return }
        UserDefaults.standard.set(path.isEmpty ? nil : path, forKey: AppSettings.iCloudSyncDirectoryKey)
        if isEnabled {
            Task {
                await coordinator.resetDirectory(path)
                await coordinator.syncNow()
            }
        }
    }

    // MARK: - Lifecycle

    /// Called once the service has a loaded configuration.
    func start() {
        if isEnabled {
            registerPollActivity()
        }
        Task { await coordinator.start() }
    }

    func stop() {
        unregisterPollActivity()
        Task { await coordinator.stop() }
    }

    /// Registers the OS-scheduled cloud poll; replacing a previous registration is
    /// handled inside `BackgroundTasks` (the old activity is invalidated first).
    private func registerPollActivity() {
        backgroundTasks.register(
            identifier: BackgroundTasks.Identifier.configSyncPoll,
            interval: Self.pollActivityInterval,
            tolerance: Self.pollActivityTolerance
        ) { [coordinator] in
            await coordinator.pollCloud()
        }
    }

    private func unregisterPollActivity() {
        backgroundTasks.unregister(identifier: BackgroundTasks.Identifier.configSyncPoll)
    }

    // MARK: - Triggers

    /// ConfigWatcher's signal: the file on disk changed, so the cloud copy may need it.
    func noteLocalConfigChanged() {
        Task { await coordinator.noteLocalConfigChanged() }
    }

    /// "立即同步" — ignores the debounce and the change markers.
    public func syncNow() {
        Task { await coordinator.syncNow() }
    }
}
