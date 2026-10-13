import XCTest
@testable import NtfyxCore

/// ConfigStore behavior (audit E3): in-memory truth, internal saves with echo
/// suppression, and external reload/failure handling. Stateless file helpers
/// (sample/initial creation) are exercised via `ConfigFile`.
@MainActor
final class ConfigStoreTests: XCTestCase {
    // XCTest invokes setUp/tearDown through nonisolated ObjC entry points; the value is
    // only ever touched on the main thread where XCTest runs.
    nonisolated(unsafe) var tempConfigPath: String!

    override func setUp() {
        super.setUp()
        tempConfigPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-config-\(UUID().uuidString).yml").path
    }

    override func tearDown() {
        if let path = tempConfigPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        super.tearDown()
    }

    // MARK: - Loading config

    func testLoadConfigFileNotFound() {
        let store = ConfigStore()
        XCTAssertThrowsError(try store.load(from: "/nonexistent/path/config.yml")) { error in
            if case ConfigError.fileNotFound = error {
                // Expected
            } else {
                XCTFail("Expected fileNotFound error, got \(error)")
            }
        }
    }

    func testLoadValidConfig() throws {
        let yaml = """
        servers:
          - url: https://ntfy.sh
            topics:
              - name: alerts
                icon_symbol: bell.fill
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)

        let store = ConfigStore()
        try store.load(from: tempConfigPath)

        XCTAssertNotNil(store.config)
        XCTAssertEqual(store.config?.servers.count, 1)
        XCTAssertEqual(store.config?.servers.first?.url, "https://ntfy.sh")
        XCTAssertEqual(store.activePath, tempConfigPath)
    }

    func testLoadConfigWithMultipleServers() throws {
        let yaml = """
        servers:
          - url: https://ntfy.sh
            topics:
              - name: public
                icon_symbol: globe
          - url: https://private.example.com
            token: secret123
            topics:
              - name: private
                icon_symbol: lock
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)

        let store = ConfigStore()
        try store.load(from: tempConfigPath)

        XCTAssertEqual(store.config?.servers.count, 2)
        XCTAssertEqual(store.config?.allTopics.count, 2)
        XCTAssertEqual(store.config?.servers[1].token, "secret123")
    }

    func testLoadInvalidYaml() throws {
        let invalidYaml = """
        servers:
          - url: https://ntfy.sh
            topics:
              - name: [invalid
        """
        try invalidYaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)

        let store = ConfigStore()
        XCTAssertThrowsError(try store.load(from: tempConfigPath))
    }

    // MARK: - Topic lookup

    func testTopicConfigLookup() throws {
        let yaml = """
        servers:
          - url: https://ntfy.sh
            topics:
              - name: alerts
                icon_symbol: bell.fill
                silent: true
              - name: news
                icon_symbol: newspaper
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)

        let store = ConfigStore()
        try store.load(from: tempConfigPath)

        let alertsTopic = store.topicConfig(serverURL: "https://ntfy.sh", topic: "alerts")
        XCTAssertNotNil(alertsTopic)
        XCTAssertEqual(alertsTopic?.iconSymbol, "bell.fill")
        XCTAssertEqual(alertsTopic?.silent, true)

        let newsTopic = store.topicConfig(serverURL: "https://ntfy.sh", topic: "news")
        XCTAssertNotNil(newsTopic)
        XCTAssertEqual(newsTopic?.iconSymbol, "newspaper")

        let unknownTopic = store.topicConfig(serverURL: "https://ntfy.sh", topic: "nonexistent")
        XCTAssertNil(unknownTopic)
    }

    /// The same topic name on different servers must resolve to each server's own config.
    func testTopicConfigLookupIsServerScoped() throws {
        let yaml = """
        servers:
          - url: https://ntfy.sh
            topics:
              - name: alerts
                icon_symbol: bell.fill
                silent: true
          - url: https://private.example.com
            topics:
              - name: alerts
                icon_symbol: exclamationmark.triangle
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)

        let store = ConfigStore()
        try store.load(from: tempConfigPath)

        let publicAlerts = store.topicConfig(serverURL: "https://ntfy.sh", topic: "alerts")
        XCTAssertEqual(publicAlerts?.iconSymbol, "bell.fill")
        XCTAssertEqual(publicAlerts?.silent, true)

        let privateAlerts = store.topicConfig(serverURL: "https://private.example.com", topic: "alerts")
        XCTAssertEqual(privateAlerts?.iconSymbol, "exclamationmark.triangle")
        XCTAssertNil(privateAlerts?.silent)

        // Unknown server → no config, even when the topic name exists elsewhere.
        XCTAssertNil(store.topicConfig(serverURL: "https://other.example.com", topic: "alerts"))
    }

    func testServerLookupByURL() throws {
        let yaml = """
        servers:
          - url: https://ntfy.sh
            topics:
              - name: alerts
          - url: https://private.example.com
            allowed_domains: []
            topics:
              - name: alerts
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)

        let store = ConfigStore()
        try store.load(from: tempConfigPath)

        XCTAssertEqual(store.serverConfig(forURL: "https://ntfy.sh")?.allowedDomains, nil)
        XCTAssertEqual(store.serverConfig(forURL: "https://private.example.com")?.allowedDomains, [])
        XCTAssertNil(store.serverConfig(forURL: "https://missing.example.com"))
    }

    // MARK: - Sample config creation (stateless ConfigFile)

    func testCreateSampleConfig() throws {
        let samplePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-config-\(UUID().uuidString).yml").path
        defer { try? FileManager.default.removeItem(atPath: samplePath) }

        XCTAssertTrue(try ConfigFile.createSampleConfig(at: samplePath))

        XCTAssertTrue(FileManager.default.fileExists(atPath: samplePath))

        let content = try String(contentsOfFile: samplePath, encoding: .utf8)
        XCTAssertTrue(content.contains("servers:"))
        XCTAssertTrue(content.contains("topics:"))
        XCTAssertTrue(content.contains("ntfy.sh"))
    }

    /// A user's existing config must survive a second `init` / sample-creation attempt.
    func testCreateSampleConfigNeverOverwritesExistingFile() throws {
        let existingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("existing-config-\(UUID().uuidString).yml").path
        let userConfig = "servers:\n  - url: https://mine.example\n    topics:\n      - name: private\n"
        try userConfig.write(toFile: existingPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: existingPath) }

        XCTAssertFalse(try ConfigFile.createSampleConfig(at: existingPath))

        let content = try String(contentsOfFile: existingPath, encoding: .utf8)
        XCTAssertEqual(content, userConfig)
    }

    /// A first launch has to keep running on the file it just wrote: it loads, and it
    /// subscribes to nothing — the sample's placeholder servers must never be contacted.
    func testCreateInitialConfigStartsWithoutSubscriptions() throws {
        let initialPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("initial-config-\(UUID().uuidString).yml").path
        defer { try? FileManager.default.removeItem(atPath: initialPath) }

        XCTAssertTrue(try ConfigFile.createInitialConfig(at: initialPath))
        // Writing twice must not clobber what the user configured in the meantime.
        XCTAssertFalse(try ConfigFile.createInitialConfig(at: initialPath))

        let store = ConfigStore()
        try store.load(from: initialPath)
        let config = try XCTUnwrap(store.config)
        XCTAssertTrue(config.servers.isEmpty)
        XCTAssertTrue(config.subscriptions.isEmpty)

        // The commented example stays in the file as the documentation it points at.
        let content = try String(contentsOfFile: initialPath, encoding: .utf8)
        XCTAssertTrue(content.contains("# servers:"))
        XCTAssertTrue(content.contains("ntfy.sh"))
    }

    func testCreateSampleConfigCreatesDirectory() throws {
        let nestedPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("nested-\(UUID().uuidString)")
            .appendingPathComponent("subdir")
            .appendingPathComponent("config.yml").path
        defer {
            let baseDir = (nestedPath as NSString).deletingLastPathComponent
            let parentDir = (baseDir as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: parentDir)
        }

        try ConfigFile.createSampleConfig(at: nestedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedPath))
    }

    // MARK: - Subscription writes

    /// The history window's one-click subscribe rewrites one server's topic list. Everything
    /// the user configured by hand — another server, a token, per-topic settings — has to come
    /// back out of the file unchanged, or the browser would silently cost them their setup.
    func testReplacingTopicsAddsOneTopicAndKeepsEverythingElse() throws {
        let yaml = """
        servers:
          - url: https://ntfy.sh
            token: secret-tok
            topics:
              - name: alerts
                icon_symbol: bell.fill
                silent: true
          - url: https://other.example
            topics:
              - name: keep-me
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)
        let store = ConfigStore()
        try store.load(from: tempConfigPath)

        var changes: [ConfigStore.Change] = []
        store.onChange = { changes.append($0) }

        try store.replacingTopics(serverURL: "https://ntfy.sh") { server in
            ServerConfig(
                url: server.url, token: server.token,
                topics: server.topics + [TopicConfig(name: "releases")]
            )
        }

        // Memory already carries the write; the callback announces exactly one internal save.
        XCTAssertEqual(changes, [.internalSave])
        let ntfy = store.config?.servers.first { $0.url == "https://ntfy.sh" }
        XCTAssertEqual(ntfy?.topics.map(\.name), ["alerts", "releases"])
        XCTAssertEqual(ntfy?.token, "secret-tok")
        XCTAssertEqual(ntfy?.topics.first?.iconSymbol, "bell.fill")
        XCTAssertEqual(ntfy?.topics.first?.silent, true)
        XCTAssertEqual(
            store.config?.servers.first { $0.url == "https://other.example" }?.topics.map(\.name),
            ["keep-me"]
        )

        // And the file on disk says the same.
        let reloaded = ConfigStore()
        try reloaded.load(from: tempConfigPath)
        XCTAssertEqual(
            reloaded.config?.servers.first { $0.url == "https://ntfy.sh" }?.topics.map(\.name),
            ["alerts", "releases"]
        )
    }

    /// Dropping a subscription is the same write with one entry removed.
    func testReplacingTopicsRemovesOneTopic() throws {
        let yaml = """
        servers:
          - url: https://ntfy.sh
            topics:
              - name: alerts
              - name: releases
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)
        let store = ConfigStore()
        try store.load(from: tempConfigPath)

        try store.replacingTopics(serverURL: "https://ntfy.sh") { server in
            ServerConfig(
                url: server.url, token: server.token,
                topics: server.topics.filter { $0.name != "alerts" }
            )
        }

        XCTAssertEqual(store.config?.servers.first?.topics.map(\.name), ["releases"])
    }

    func testReplacingTopicsRejectsAnUnknownServer() throws {
        let yaml = """
        servers:
          - url: https://ntfy.sh
            topics:
              - name: alerts
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)
        let store = ConfigStore()
        try store.load(from: tempConfigPath)

        XCTAssertThrowsError(
            try store.replacingTopics(serverURL: "https://gone.example") { $0 }
        )
        XCTAssertEqual(try String(contentsOfFile: tempConfigPath, encoding: .utf8), yaml)
    }

    // MARK: - Save and echo suppression (audit E3)

    func testSaveFiresInternalSaveAndPersists() throws {
        let yaml = """
        servers:
          - url: https://a.example
            topics:
              - name: alerts
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)
        let store = ConfigStore()
        try store.load(from: tempConfigPath)

        var changes: [ConfigStore.Change] = []
        store.onChange = { changes.append($0) }

        let updated = AppConfig(
            servers: [ServerConfig(url: "https://a.example", topics: [TopicConfig(name: "alerts"), TopicConfig(name: "news")])]
        )
        try store.save(updated)

        XCTAssertEqual(changes, [.internalSave])
        XCTAssertEqual(store.config?.servers.first?.topics.map(\.name), ["alerts", "news"])
        let onDisk = try ConfigFile.read(from: tempConfigPath)
        XCTAssertEqual(onDisk.config.servers.first?.topics.map(\.name), ["alerts", "news"])
    }

    /// The watcher event our own atomic save inevitably generates must be swallowed:
    /// same raw bytes means nothing external happened, so no `.externalReload`.
    func testWatcherEventAfterOwnSaveIsSuppressedAsEcho() throws {
        let yaml = """
        servers:
          - url: https://a.example
            topics:
              - name: alerts
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)
        let store = ConfigStore()
        try store.load(from: tempConfigPath)

        var changes: [ConfigStore.Change] = []
        store.onChange = { changes.append($0) }

        try store.save(AppConfig(
            servers: [ServerConfig(url: "https://a.example", topics: [TopicConfig(name: "alerts"), TopicConfig(name: "news")])]
        ))
        changes.removeAll()

        // The file's bytes are exactly what the store just wrote.
        store.simulateWatcherEventForTesting()
        XCTAssertTrue(changes.isEmpty, "own-save echo must not produce a change callback")
    }

    /// A valid hand-edit lands as `.externalReload` and replaces the live config.
    func testExternalEditReloads() throws {
        let yaml = """
        servers:
          - url: https://a.example
            topics:
              - name: alerts
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)
        let store = ConfigStore()
        try store.load(from: tempConfigPath)

        var changes: [ConfigStore.Change] = []
        store.onChange = { changes.append($0) }

        let edited = """
        servers:
          - url: https://a.example
            topics:
              - name: alerts
              - name: news
        """
        try edited.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)
        store.simulateWatcherEventForTesting()

        XCTAssertEqual(changes, [.externalReload])
        XCTAssertEqual(store.config?.servers.first?.topics.map(\.name), ["alerts", "news"])
        XCTAssertNil(store.loadError)
    }

    /// A broken hand-edit must not take the service offline: keep the previous config,
    /// report `.externalFailure` and surface a load error until a later good edit.
    func testExternalBrokenYAMLKeepsOldConfigAndReportsFailure() throws {
        let good = """
        servers:
          - url: https://a.example
            topics:
              - name: alerts
        """
        try good.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)
        let store = ConfigStore()
        try store.load(from: tempConfigPath)

        var changes: [ConfigStore.Change] = []
        store.onChange = { changes.append($0) }

        let broken = """
        servers:
          - url: https://a.example
            topics:
              - name: [unclosed
        """
        try broken.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)
        store.simulateWatcherEventForTesting()

        XCTAssertEqual(changes, [.externalFailure])
        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(store.config?.servers.first?.topics.map(\.name), ["alerts"],
                       "live config must stay on the last known good state")

        // A subsequent good edit clears the error and reloads.
        let fixed = """
        servers:
          - url: https://a.example
            topics:
              - name: alerts
              - name: recovered
        """
        try fixed.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)
        store.simulateWatcherEventForTesting()

        XCTAssertEqual(changes, [.externalFailure, .externalReload])
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.config?.servers.first?.topics.map(\.name), ["alerts", "recovered"])
    }

    /// A delete-then-recreate sequence: the missing-file event is ignored, the later
    /// create event delivers the new config.
    func testExternalDeletionThenRecreation() throws {
        let yaml = """
        servers:
          - url: https://a.example
            topics:
              - name: alerts
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)
        let store = ConfigStore()
        try store.load(from: tempConfigPath)

        var changes: [ConfigStore.Change] = []
        store.onChange = { changes.append($0) }

        try FileManager.default.removeItem(atPath: tempConfigPath)
        store.simulateWatcherEventForTesting()
        XCTAssertTrue(changes.isEmpty, "missing file must be ignored, awaiting recreation")
        XCTAssertEqual(store.config?.servers.first?.topics.map(\.name), ["alerts"])

        let recreated = """
        servers:
          - url: https://b.example
            topics:
              - name: fresh
        """
        try recreated.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)
        store.simulateWatcherEventForTesting()
        XCTAssertEqual(changes, [.externalReload])
        XCTAssertEqual(store.config?.servers.first?.url, "https://b.example")
    }

    // MARK: - Active path pinning (serve --config)

    /// A `serve --config PATH` instance pins the path; a path-less reload re-reads that
    /// same file instead of falling back to the default location.
    func testExplicitPathIsPinnedForReloadsAndSaves() throws {
        let yaml = """
        servers:
          - url: https://a.example
            topics:
              - name: alerts
        """
        try yaml.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)
        let store = ConfigStore()
        try store.load(from: tempConfigPath)
        XCTAssertEqual(store.activePath, tempConfigPath)
        XCTAssertNotEqual(store.activePath, ConfigStore.defaultConfigPath)

        let edited = yaml.replacingOccurrences(of: "name: alerts", with: "name: other")
        try edited.write(toFile: tempConfigPath, atomically: true, encoding: .utf8)
        try store.reloadFromDisk()
        XCTAssertEqual(store.config?.servers.first?.topics.map(\.name), ["other"])

        try store.save(store.config!)
        let saved = try String(contentsOfFile: tempConfigPath, encoding: .utf8)
        XCTAssertTrue(saved.contains("name: other"))
        XCTAssertEqual(store.activePath, tempConfigPath)
    }
}
