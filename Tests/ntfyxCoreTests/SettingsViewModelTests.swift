import XCTest
@testable import NtfyxCore

// MARK: - Mock URLProtocol for connectivity probes

/// Answers probes with programmable per-path statuses and records every request,
/// so token checks and publish results can be asserted without a server.
private final class ProbeMockProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _statuses: [String: Int] = [:]
    nonisolated(unsafe) private static var _requests: [URLRequest] = []

    static func configure(_ statuses: [String: Int]) {
        lock.lock(); _statuses = statuses; _requests = []; lock.unlock()
    }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    static func status(for path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return _statuses[path] ?? 200
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        ProbeMockProtocol.lock.lock()
        ProbeMockProtocol._requests.append(request)
        let status = ProbeMockProtocol._statuses[path] ?? 200
        ProbeMockProtocol.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = path.hasSuffix("/json") && request.httpMethod == "GET"
            ? Data(#"{"healthcheck":true,"version":"3.5.9"}"#.utf8)
            : Data()
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func probeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ProbeMockProtocol.self]
    return URLSession(configuration: config)
}

/// The settings save flow must not drop hand-written server-level security
/// options (allowed_schemes / allowed_domains) from the config file.
@MainActor
final class SettingsViewModelTests: XCTestCase {

    private func tempPath(_ name: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("svm-\(name)-\(UUID().uuidString).yml").path
    }

    func testSavePreservesAllowedSchemesAndDomains() throws {
        let src = tempPath("src")
        let dst = tempPath("dst")
        defer { try? FileManager.default.removeItem(atPath: src); try? FileManager.default.removeItem(atPath: dst) }

        let yaml = """
        servers:
          - url: https://ntfy.example.com
            allowed_schemes:
              - https
              - myapp
            allowed_domains:
              - "*.trusted.org"
              - example.com
            topics:
              - name: alerts
          - url: https://second.example.com
            allowed_domains: []
            topics:
              - name: public
        """
        try yaml.write(toFile: src, atomically: true, encoding: .utf8)
        let store = ConfigStore()
        try store.load(from: src)

        let vm = SettingsViewModel(configStore: store)
        vm.loadFromConfig()

        // Load maps server-level restrictions into the editable model.
        XCTAssertEqual(vm.servers.count, 2)
        XCTAssertEqual(vm.servers[0].allowedSchemes, ["https", "myapp"])
        XCTAssertEqual(vm.servers[0].allowedDomains, ["*.trusted.org", "example.com"])
        XCTAssertEqual(vm.servers[1].allowedDomains, [])
        XCTAssertNil(vm.servers[1].allowedSchemes)

        vm.save(to: dst)
        XCTAssertNil(vm.saveError, "save failed: \(vm.saveError ?? "")")

        // Re-read the written file: both values and nil-vs-empty semantics survive the round-trip.
        try store.load(from: dst)
        let servers = store.config?.servers ?? []
        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual(servers[0].allowedSchemes, ["https", "myapp"])
        XCTAssertEqual(servers[0].allowedDomains, ["*.trusted.org", "example.com"])
        XCTAssertEqual(servers[1].allowedDomains, [])
        XCTAssertNil(servers[1].allowedSchemes)
    }

    func testSaveWithoutRestrictionsKeepsThemAbsent() throws {
        let src = tempPath("src")
        let dst = tempPath("dst")
        defer { try? FileManager.default.removeItem(atPath: src); try? FileManager.default.removeItem(atPath: dst) }

        let yaml = """
        servers:
          - url: https://ntfy.example.com
            topics:
              - name: alerts
        """
        try yaml.write(toFile: src, atomically: true, encoding: .utf8)
        let store = ConfigStore()
        try store.load(from: src)

        let vm = SettingsViewModel(configStore: store)
        vm.loadFromConfig()
        vm.servers[0].topics = [EditableTopic(name: "alerts"), EditableTopic(name: "deployments")]
        vm.save(to: dst)
        XCTAssertNil(vm.saveError, "save failed: \(vm.saveError ?? "")")

        try store.load(from: dst)
        let server = store.config?.servers.first
        XCTAssertNil(server?.allowedSchemes)
        XCTAssertNil(server?.allowedDomains)
        XCTAssertEqual(server?.topics.map(\.name), ["alerts", "deployments"])
    }

    // MARK: - Validation (ConfigValidator wiring)

    func testSaveRejectsIncompleteServerURL() throws {
        let dst = tempPath("dst")
        defer { try? FileManager.default.removeItem(atPath: dst) }

        let vm = SettingsViewModel(configStore: ConfigStore())
        vm.addServer()  // default "https://" with one blank topic row
        vm.servers[0].topics[0].name = "alerts"

        vm.save(to: dst)

        XCTAssertNotNil(vm.saveError, "an URL without host must not be savable")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dst),
            "invalid config must be rejected before the file is written"
        )
    }

    func testSaveRejectsNonHTTPScheme() throws {
        let dst = tempPath("dst")
        defer { try? FileManager.default.removeItem(atPath: dst) }

        let vm = SettingsViewModel(configStore: ConfigStore())
        vm.addServer()
        vm.servers[0].url = "ftp://example.com"
        vm.servers[0].topics[0].name = "alerts"

        vm.save(to: dst)

        XCTAssertNotNil(vm.saveError, "non-http(s) server URLs must be rejected")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst))
    }

    func testSaveTrimsServerURLAndTopicNames() throws {
        let dst = tempPath("dst")
        defer { try? FileManager.default.removeItem(atPath: dst) }

        let store = ConfigStore()
        let vm = SettingsViewModel(configStore: store)
        vm.addServer()
        vm.servers[0].url = "  https://spaced.example.com  "
        vm.servers[0].topics[0].name = " alerts "

        vm.save(to: dst)
        XCTAssertNil(vm.saveError, "save failed: \(vm.saveError ?? "")")

        try store.load(from: dst)
        let server = store.config?.servers.first
        XCTAssertEqual(server?.url, "https://spaced.example.com")
        XCTAssertEqual(server?.topics.first?.name, "alerts")
    }

    // MARK: - Display name (中文备注)

    func testDisplayNameRoundTripsThroughTheEditor() throws {
        let src = tempPath("src")
        let dst = tempPath("dst")
        defer { try? FileManager.default.removeItem(atPath: src); try? FileManager.default.removeItem(atPath: dst) }

        let yaml = """
        servers:
          - url: https://ntfy.example.com
            topics:
              - name: alerts
                display_name: 生产告警
        """
        try yaml.write(toFile: src, atomically: true, encoding: .utf8)
        let store = ConfigStore()
        try store.load(from: src)

        let vm = SettingsViewModel(configStore: store)
        vm.loadFromConfig()
        XCTAssertEqual(vm.servers[0].topics[0].displayName, "生产告警")
        XCTAssertEqual(vm.servers[0].topics[0].label, "生产告警")
        XCTAssertEqual(vm.servers[0].topics[0].name, "alerts")

        vm.save(to: dst)
        XCTAssertNil(vm.saveError, "save failed: \(vm.saveError ?? "")")

        try store.load(from: dst)
        let topic = store.config?.servers.first?.topics.first
        XCTAssertEqual(topic?.name, "alerts")
        XCTAssertEqual(topic?.displayName, "生产告警")
    }

    func testDisplayNameIsTrimmedAndBlankBecomesAbsent() throws {
        let dst = tempPath("dst")
        defer { try? FileManager.default.removeItem(atPath: dst) }

        let store = ConfigStore()
        let vm = SettingsViewModel(configStore: store)
        vm.addServer()
        vm.servers[0].url = "https://a.example.com"
        vm.servers[0].topics[0].name = "alerts"
        vm.servers[0].topics[0].displayName = "  生产告警 "
        vm.addTopic(to: vm.servers[0].id)
        vm.servers[0].topics[1].name = "releases"
        vm.servers[0].topics[1].displayName = "   "

        vm.save(to: dst)
        XCTAssertNil(vm.saveError, "save failed: \(vm.saveError ?? "")")

        try store.load(from: dst)
        let topics = store.config?.servers.first?.topics ?? []
        XCTAssertEqual(topics.map(\.displayName), ["生产告警", nil])
        XCTAssertEqual(topics.map(\.label), ["生产告警", "releases"])

        let text = try String(contentsOfFile: dst, encoding: .utf8)
        XCTAssertFalse(text.contains("display_name: \"\""), text)
    }

    func testSaveRejectsOverlongDisplayName() throws {
        let dst = tempPath("dst")
        defer { try? FileManager.default.removeItem(atPath: dst) }

        let vm = SettingsViewModel(configStore: ConfigStore())
        vm.addServer()
        vm.servers[0].url = "https://a.example.com"
        vm.servers[0].topics[0].name = "alerts"
        vm.servers[0].topics[0].displayName = String(repeating: "警", count: 65)

        vm.save(to: dst)

        XCTAssertNotNil(vm.saveError, "an unreadable note must not be savable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst))
    }

    // MARK: - Connectivity tests (audit 3.2)

    private func makeServer(url: String = "https://probe.example", token: String = "", topicName: String = "alerts") -> EditableServer {
        EditableServer(url: url, token: token, topics: [EditableTopic(name: topicName)])
    }

    private func waitUntil(timeoutSeconds: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met before timeout")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testTestConnectionReportsVersion() async throws {
        ProbeMockProtocol.configure(["/json": 200])
        let vm = SettingsViewModel(configStore: ConfigStore())
        vm.probeSession = probeSession()
        let server = makeServer()

        vm.testConnection(for: server)
        XCTAssertEqual(vm.serverTestStates[server.id], .testing)

        try await waitUntil { vm.serverTestStates[server.id] == .reachable(version: "3.5.9") }
    }

    func testTestConnectionChecksTokenAgainstFirstTopic() async throws {
        ProbeMockProtocol.configure(["/json": 200, "/alerts/json": 401])
        let vm = SettingsViewModel(configStore: ConfigStore())
        vm.probeSession = probeSession()
        let server = makeServer(token: "tk_bad")

        vm.testConnection(for: server)
        try await waitUntil { vm.serverTestStates[server.id] == .tokenRejected }

        let poll = ProbeMockProtocol.requests.first { $0.url?.path == "/alerts/json" }
        XCTAssertEqual(poll?.value(forHTTPHeaderField: "Authorization"), "Bearer tk_bad")
    }

    func testTestConnectionWithoutTokenSkipsPoll() async throws {
        ProbeMockProtocol.configure(["/json": 200])
        let vm = SettingsViewModel(configStore: ConfigStore())
        vm.probeSession = probeSession()
        let server = makeServer()

        vm.testConnection(for: server)
        try await waitUntil { vm.serverTestStates[server.id] != nil && vm.serverTestStates[server.id] != .testing }

        XCTAssertEqual(ProbeMockProtocol.requests.count, 1)  // only the /json info probe
    }

    func testSendTestNotificationPublishesWithToken() async throws {
        ProbeMockProtocol.configure(["/alerts": 200])
        let vm = SettingsViewModel(configStore: ConfigStore())
        vm.probeSession = probeSession()
        let server = makeServer(token: "tk_write")
        let topic = server.topics[0]

        vm.sendTestNotification(in: server, topic: topic)
        try await waitUntil { vm.topicTestStates[topic.id] == .success }

        let post = ProbeMockProtocol.requests.first
        XCTAssertEqual(post?.httpMethod, "POST")
        XCTAssertEqual(post?.value(forHTTPHeaderField: "Authorization"), "Bearer tk_write")
        // URLSession silently drops non-ASCII header values, so the Title must be ASCII.
        let title = post?.value(forHTTPHeaderField: "Title")
        XCTAssertNotNil(title)
        XCTAssertEqual(title?.unicodeScalars.allSatisfy { $0.isASCII }, true, "Title header must be ASCII: \(title ?? "")")
        XCTAssertEqual(title, "test \(topic.name)")
    }

    func testSendTestNotificationSurfacesWriteRejection() async throws {
        ProbeMockProtocol.configure(["/alerts": 403])
        let vm = SettingsViewModel(configStore: ConfigStore())
        vm.probeSession = probeSession()
        let server = makeServer()
        let topic = server.topics[0]

        vm.sendTestNotification(in: server, topic: topic)
        try await waitUntil {
            if case .failed(let reason) = vm.topicTestStates[topic.id] {
                return reason.contains("403")
            }
            return false
        }
    }

    // MARK: - Security option editing (audit 3.3)

    func testRestrictionModesLoadFromYAML() throws {
        let src = tempPath("src")
        defer { try? FileManager.default.removeItem(atPath: src) }

        let yaml = """
        servers:
          - url: https://ntfy.example.com
            allowed_schemes:
              - https
              - myapp
            allowed_domains:
              - "*.trusted.org"
            topics:
              - name: alerts
          - url: https://second.example.com
            allowed_domains: []
            topics:
              - name: public
        """
        try yaml.write(toFile: src, atomically: true, encoding: .utf8)
        let store = ConfigStore()
        try store.load(from: src)

        let vm = SettingsViewModel(configStore: store)
        vm.loadFromConfig()

        XCTAssertEqual(vm.servers[0].schemesMode, .custom)
        XCTAssertEqual(vm.servers[0].schemesInput, "https, myapp")
        XCTAssertEqual(vm.servers[0].domainsMode, .custom)
        XCTAssertEqual(vm.servers[0].domainsInput, "*.trusted.org")
        XCTAssertEqual(vm.servers[1].schemesMode, .off)
        XCTAssertEqual(vm.servers[1].domainsMode, .denyAll)
    }

    func testRestrictionEditingWritesBackAllThreeModes() throws {
        let src = tempPath("src")
        let dst = tempPath("dst")
        defer { try? FileManager.default.removeItem(atPath: src); try? FileManager.default.removeItem(atPath: dst) }

        let yaml = """
        servers:
          - url: https://ntfy.example.com
            allowed_schemes:
              - https
              - myapp
            allowed_domains:
              - "*.trusted.org"
            topics:
              - name: alerts
        """
        try yaml.write(toFile: src, atomically: true, encoding: .utf8)
        let store = ConfigStore()
        try store.load(from: src)

        let vm = SettingsViewModel(configStore: store)
        vm.loadFromConfig()

        vm.servers[0].schemesInput = "https, Custom"        // edit the custom list (case folds)
        vm.servers[0].domainsMode = .off                    // drop the domain whitelist
        vm.addServer()                                      // new server → custom empty domain list
        vm.servers[1].url = "https://second.example.com"
        vm.servers[1].topics[0].name = "public"
        vm.servers[1].domainsMode = .custom
        vm.servers[1].domainsInput = "  "

        vm.save(to: dst)
        XCTAssertNil(vm.saveError, "save failed: \(vm.saveError ?? "")")

        try store.load(from: dst)
        let servers = store.config?.servers ?? []
        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual(servers[0].allowedSchemes, ["https", "custom"])
        XCTAssertNil(servers[0].allowedDomains)
        XCTAssertEqual(servers[1].allowedDomains, [])   // custom + empty input = deny-all
        XCTAssertNil(servers[1].allowedSchemes)
    }
}
