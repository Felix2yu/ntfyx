import XCTest
@testable import NtfyxCore

/// Directory-level config watcher (audit E3): atomic replacement, late creation,
/// in-place writes, burst coalescing and unrelated-file noise.
@MainActor
final class ConfigWatcherTests: XCTestCase {
    // XCTest invokes the setUp/tearDown overrides through nonisolated ObjC entry points;
    // the values are only ever touched on the main thread where XCTest runs.
    nonisolated(unsafe) var tempDir: URL!
    nonisolated(unsafe) var tempConfigPath: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("configwatcher-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tempConfigPath = tempDir.appendingPathComponent("config.yml").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeConfig(_ name: String, atomically: Bool = true) throws {
        try """
        servers:
          - url: https://ntfy.sh
            topics:
              - name: \(name)
        """.write(toFile: tempConfigPath, atomically: atomically, encoding: .utf8)
    }

    // MARK: - Installation

    func testWatcherInitializesWithDefaultPath() {
        let watcher = ConfigWatcher()
        // Should not crash and use default path
        XCTAssertNotNil(watcher)
    }

    func testWatcherInitializesWithCustomPath() {
        let watcher = ConfigWatcher(configPath: tempConfigPath)
        XCTAssertNotNil(watcher)
    }

    func testStopWatchingCanBeCalledMultipleTimes() {
        let watcher = ConfigWatcher(configPath: tempConfigPath)

        watcher.startWatching {}

        // Should not crash when called multiple times
        watcher.stopWatching()
        watcher.stopWatching()
        watcher.stopWatching()
    }

    func testWatcherStopsBeforeDeallocation() {
        var watcher: ConfigWatcher? = ConfigWatcher(configPath: tempConfigPath)
        watcher?.startWatching {}

        // Should not crash on deallocation
        watcher = nil

        // If we reach here without crashing, the test passes
        XCTAssertNil(watcher)
    }

    // MARK: - Change delivery

    func testWatcherCallsCallbackOnInPlaceFileChange() throws {
        try writeConfig("seed")
        let watcher = ConfigWatcher(configPath: tempConfigPath)
        let expectation = XCTestExpectation(description: "Config change callback called")

        watcher.startWatching {
            expectation.fulfill()
        }
        // Give time for the sources to install.
        Thread.sleep(forTimeInterval: 0.1)

        // Non-atomic in-place rewrite (the file source's [.write, .extend] case).
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tempConfigPath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("  # touched \(UUID())\n".utf8))
        try handle.close()

        wait(for: [expectation], timeout: 3.0)
        watcher.stopWatching()
    }

    /// The case the old file-only watcher missed: `write(tmp); rename(tmp, config)`
    /// replaces the directory entry; the directory source must still deliver exactly
    /// one settled callback.
    func testWatcherDeliversAtomicTmpRename() throws {
        try writeConfig("seed")
        let watcher = ConfigWatcher(configPath: tempConfigPath)
        let changed = XCTestExpectation(description: "atomic replacement delivered")
        changed.assertForOverFulfill = true
        changed.expectedFulfillmentCount = 1

        watcher.startWatching {
            changed.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)

        // Real atomic save: temp file in the same directory, then rename(2) over target.
        let tmpPath = tempDir.appendingPathComponent(".config.yml.tmp-\(UUID().uuidString)").path
        try """
        servers:
          - url: https://ntfy.sh
            topics:
              - name: atomic
        """.write(toFile: tmpPath, atomically: true, encoding: .utf8)
        XCTAssertEqual(rename(tmpPath, tempConfigPath), 0)

        wait(for: [changed], timeout: 3.0)
        watcher.stopWatching()
    }

    /// The file need not exist when watching starts (first launch races the starter):
    /// creating it afterwards must still be delivered via the directory source.
    func testWatcherDeliversFileCreatedAfterStart() throws {
        let watcher = ConfigWatcher(configPath: tempConfigPath)
        let changed = XCTestExpectation(description: "late-created file delivered")

        watcher.startWatching {
            changed.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempConfigPath))

        try writeConfig("created-late")

        wait(for: [changed], timeout: 3.0)
        watcher.stopWatching()
    }

    /// Delete followed by recreate (some editors' save dance) must re-arm the file
    /// source and deliver the recreation.
    func testWatcherHandlesFileRecreation() throws {
        try writeConfig("seed")
        let watcher = ConfigWatcher(configPath: tempConfigPath)
        let expectation = XCTestExpectation(description: "Config change callback after recreation")
        expectation.assertForOverFulfill = false

        watcher.startWatching {
            expectation.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)

        try FileManager.default.removeItem(atPath: tempConfigPath)
        Thread.sleep(forTimeInterval: ConfigWatcher.settleInterval + 0.2)

        try writeConfig("recreated")

        wait(for: [expectation], timeout: 3.0)
        watcher.stopWatching()
    }

    /// Several filesystem events inside one quiet window collapse into one callback;
    /// without coalescing a single editor save routinely fires 3-4 times.
    func testBurstCoalescesIntoOneCallback() throws {
        try writeConfig("seed")
        let watcher = ConfigWatcher(configPath: tempConfigPath)
        let settled = XCTestExpectation(description: "burst settles once")
        settled.expectedFulfillmentCount = 1
        settled.assertForOverFulfill = true

        watcher.startWatching {
            settled.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)

        // Four atomic rewrites spaced well inside the 0.25 s settle window.
        for i in 0..<4 {
            let tmpPath = tempDir.appendingPathComponent(".t-\(i).yml").path
            try """
            servers:
              - url: https://ntfy.sh
                topics:
                  - name: burst-\(i)
            """.write(toFile: tmpPath, atomically: true, encoding: .utf8)
            XCTAssertEqual(rename(tmpPath, tempConfigPath), 0)
            Thread.sleep(forTimeInterval: 0.05)
        }

        wait(for: [settled], timeout: 3.0)
        // Let a second window pass to make sure no trailing callback arrives.
        Thread.sleep(forTimeInterval: ConfigWatcher.settleInterval * 2)
        watcher.stopWatching()
    }

    /// The directory source also reports *other* files appearing next to the config.
    /// The watcher deliberately does not filter those (it cannot know the owner's raw
    /// state); `ConfigStore` drops them as same-bytes echoes. This test pins both ends
    /// of that contract.
    func testUnrelatedFileEventIsDeliveredButFilteredByStore() throws {
        let seed = """
        servers:
          - url: https://ntfy.sh
            topics:
              - name: test
        """
        try seed.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)
        let watcher = ConfigWatcher(configPath: tempConfigPath)
        let delivered = XCTestExpectation(description: "directory event delivered")

        watcher.startWatching {
            delivered.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)

        let unrelated = tempDir.appendingPathComponent("notes-\(UUID().uuidString).txt").path
        try "hello".write(toFile: unrelated, atomically: true, encoding: .utf8)

        wait(for: [delivered], timeout: 3.0)
        watcher.stopWatching()

        // Store side: same raw text → the event changes nothing and fires no callback.
        let store = ConfigStore()
        try store.load(from: tempConfigPath)
        var changes: [ConfigStore.Change] = []
        store.onChange = { changes.append($0) }

        store.simulateWatcherEventForTesting()
        XCTAssertTrue(changes.isEmpty, "unrelated-file noise must be filtered by raw comparison")
    }
}
