import XCTest
@testable import NtfyxCore

/// The cloud poll is owned by the facade: enabling sync registers one repeating OS
/// activity, disabling/stopping invalidates it (audit F3).
@MainActor
final class SyncPollSchedulingTests: XCTestCase {
    @MainActor
    private final class Harness {
        let bag = FakeActivityBag()
        let tasks: BackgroundTasks
        let service: ConfigSyncService
        /// Whether the enabled key existed before the test, so it can be restored.
        private let wasEnabled: Bool

        init() {
            tasks = BackgroundTasks { [bag] in bag.make($0) }
            service = ConfigSyncService(configStore: ConfigStore(), backgroundTasks: tasks)
            wasEnabled = UserDefaults.standard.object(forKey: AppSettings.iCloudSyncEnabledKey) != nil
                && UserDefaults.standard.bool(forKey: AppSettings.iCloudSyncEnabledKey)
            UserDefaults.standard.removeObject(forKey: AppSettings.iCloudSyncEnabledKey)
        }

        var poll: FakeSystemActivity? { bag[BackgroundTasks.Identifier.configSyncPoll] }

        var isPollRegistered: Bool {
            tasks.isRegistered(identifier: BackgroundTasks.Identifier.configSyncPoll)
        }

        func setEnabled(_ enabled: Bool) {
            UserDefaults.standard.set(enabled, forKey: AppSettings.iCloudSyncEnabledKey)
        }

        func cleanup() {
            service.stop()
            if wasEnabled {
                UserDefaults.standard.set(true, forKey: AppSettings.iCloudSyncEnabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppSettings.iCloudSyncEnabledKey)
            }
            tasks.invalidateAll()
        }
    }

    func testStartRegistersPollActivityWhenEnabled() {
        let h = Harness()
        defer { h.cleanup() }
        h.setEnabled(true)

        h.service.start()

        let fake = try? XCTUnwrap(h.poll)
        XCTAssertEqual(fake?.repeats, true)
        XCTAssertEqual(fake?.interval, 60, "系统调度的 interval 下限为 60s")
        XCTAssertEqual(fake?.tolerance, 15)
    }

    func testStartDoesNotRegisterPollActivityWhenDisabled() {
        let h = Harness()
        defer { h.cleanup() }

        h.service.start()
        XCTAssertNil(h.poll)
    }

    func testStopInvalidatesPollActivity() {
        let h = Harness()
        defer { h.cleanup() }
        h.setEnabled(true)
        h.service.start()
        let fake = h.poll
        XCTAssertNotNil(fake)

        h.service.stop()

        XCTAssertEqual(fake?.invalidateCount, 1)
        XCTAssertFalse(h.isPollRegistered, "注销后应忘记该活动")
    }

    func testSetEnabledTogglesPollActivity() {
        let h = Harness()
        defer { h.cleanup() }

        h.service.setEnabled(true)
        let fake = h.poll
        XCTAssertNotNil(fake)
        XCTAssertEqual(fake?.invalidateCount, 0)

        h.service.setEnabled(false)
        XCTAssertEqual(fake?.invalidateCount, 1)
        XCTAssertFalse(h.isPollRegistered)
    }
}
