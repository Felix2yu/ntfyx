import XCTest
@testable import NtfyxCore

/// The boundary between the on-disk config and the cloud document. Two properties carry
/// most of the risk: a machine-local setting must never travel to another Mac, and applying
/// a merged document must leave the export unchanged — otherwise every sync writes the
/// cloud file again and the devices never settle.
final class ConfigSyncTranslatorTests: XCTestCase {

    private let url = "https://a.example"

    private func syncTopic(_ name: String, iconSymbol: String? = nil, silent: Bool? = nil,
                           clickUrl: ClickUrlConfig? = nil) -> SyncTopic {
        SyncTopic(name: name, iconSymbol: iconSymbol, silent: silent, clickUrl: clickUrl)
    }

    private func syncServer(_ url: String, token: String? = nil, topics: [SyncTopic]) -> SyncServer {
        SyncServer(url: url, token: token, topics: topics)
    }

    /// A config that uses every machine-local field the feature has to leave alone.
    private func machineLocalConfig(token: String? = "yaml-token", port: UInt16? = 9292) -> AppConfig {
        let topic = TopicConfig(
            name: "alerts",
            iconPath: "/Users/me/a.png",
            iconSymbol: "bell",
            autoRunScript: "/usr/local/bin/a.sh",
            silent: true,
            clickUrl: .custom("myapp://x"),
            actions: [NotificationAction(title: "Run", type: "script", path: "/x.sh")]
        )
        return AppConfig(servers: [ServerConfig(url: url, token: token, topics: [topic])], localServerPort: port)
    }

    // MARK: - Publishing

    func testPublishedDocumentNeverCarriesAToken() {
        // Whether the credential sits inline in the YAML or nowhere at all, the cloud
        // document is token-free (E2a).
        let published = ConfigSyncTranslator.document(from: machineLocalConfig(token: "yaml-token"))
        XCTAssertNil(published.servers.first?.token)
    }

    func testPortableFieldsArePublished() {
        let published = ConfigSyncTranslator.document(from: machineLocalConfig())
        XCTAssertEqual(published.serverIndex[url]?.topicIndex["alerts"]?.clickUrl, .custom("myapp://x"))
        XCTAssertEqual(published.serverIndex[url]?.topicIndex["alerts"]?.silent, true)
    }

    func testCloudTextExcludesMachineLocalSettingsAndTokens() throws {
        let published = ConfigSyncTranslator.document(from: machineLocalConfig(token: "yaml-token"))
        let text = try CloudConfigStore.encoded(published)
        XCTAssertFalse(text.contains("auto_run_script"))
        XCTAssertFalse(text.contains("icon_path"))
        XCTAssertFalse(text.contains("actions"))
        XCTAssertFalse(text.contains("local_server_port"))
        XCTAssertFalse(text.contains("yaml-token"))
        XCTAssertFalse(text.contains("token"), "令牌键本身也不应出现在云端文件中")
    }

    // MARK: - Applying a merged document

    private func apply(_ merged: SyncDocument, to local: AppConfig, keychain: KeychainTokenReader.Outcome) -> ConfigSyncTranslator.LocalWrite {
        ConfigSyncTranslator.localWrite(from: merged, preserving: local, keychainToken: { _ in keychain })
    }

    func testApplyingKeepsMachineLocalFieldsAndOrder() {
        let merged = SyncDocument(servers: [syncServer(url, token: "kc-token",
                                                       topics: [syncTopic("alerts", iconSymbol: "bell"), syncTopic("new-from-cloud")])])
        .canonicalized
        let write = apply(merged, to: machineLocalConfig(), keychain: .value("kc-token"))

        XCTAssertEqual(write.config.localServerPort, 9292, "本地端口保持不变")
        let topics = write.config.servers.first?.topics ?? []
        XCTAssertEqual(topics.map(\.name), ["alerts", "new-from-cloud"], "本机主题在前，云端新增的排在后面")
        XCTAssertEqual(topics.first?.iconPath, "/Users/me/a.png")
        XCTAssertEqual(topics.first?.autoRunScript, "/usr/local/bin/a.sh")
        XCTAssertEqual(topics.first?.actions?.count, 1)
        XCTAssertNil(topics.last?.iconPath, "云端来的主题不带本机路径")
    }

    func testKeychainBackedServerIsLeftAloneAndYAMLIsCleared() {
        // A Keychain credential is never overwritten — not even by a legacy v1 cloud
        // token — and the synced YAML copy keeps no token at all.
        let merged = SyncDocument(servers: [syncServer(url, token: "legacy-cloud", topics: [syncTopic("alerts")])])
        let write = apply(merged, to: machineLocalConfig(token: "yaml-token"), keychain: .value("kc-token"))
        XCTAssertNil(write.config.servers.first?.token, "参与同步的服务器 YAML 不再保留令牌")
        XCTAssertTrue(write.tokenPlacements.isEmpty, "钥匙串已有值时绝不覆盖")
    }

    func testInlineTokenMigratesIntoTheKeychain() {
        let local = machineLocalConfig(token: "inline-tk", port: nil)
        // A v1 legacy token arriving in the same pass must not win over the Mac's own
        // inline credential.
        let merged = SyncDocument(servers: [syncServer(url, token: "legacy-cloud", topics: [syncTopic("alerts")])])
        let write = apply(merged, to: local, keychain: .absent)
        XCTAssertEqual(write.tokenPlacements[url], .keychain("inline-tk"))
        XCTAssertNil(write.config.servers.first?.token, "迁移后 YAML 字段清空")
    }

    func testLegacyCloudTokenBackfillsAnEmptyKeychainOnce() {
        // A v1 cloud file arriving on a Mac with neither Keychain nor inline token:
        // the credential is recovered into the Keychain, never into the plaintext file.
        let local = machineLocalConfig(token: nil, port: nil)
        let merged = SyncDocument(servers: [syncServer(url, token: "from-v1-cloud", topics: [syncTopic("alerts")])])
        let write = apply(merged, to: local, keychain: .absent)
        XCTAssertEqual(write.tokenPlacements[url], .keychain("from-v1-cloud"))
        XCTAssertNil(write.config.servers.first?.token)
    }

    func testV2CloudDocumentWithoutTokenAddsNoCredential() {
        // The announced behaviour change: a Mac newly joining sync gets the subscription
        // but has to paste the token in once itself.
        let local = machineLocalConfig(token: nil, port: nil)
        let merged = SyncDocument(servers: [syncServer(url, token: nil, topics: [syncTopic("alerts")])])
        let write = apply(merged, to: local, keychain: .absent)
        XCTAssertTrue(write.tokenPlacements.isEmpty)
        XCTAssertNil(write.config.servers.first?.token)
    }

    func testLegacyTokenOnACloudOnlyServerGoesToTheKeychain() {
        let merged = SyncDocument(servers: [syncServer(url, token: "from-v1-cloud", topics: [syncTopic("alerts")])])
        let write = apply(merged, to: AppConfig(servers: [], localServerPort: nil), keychain: .absent)
        XCTAssertEqual(write.tokenPlacements[url], .keychain("from-v1-cloud"))
        XCTAssertNil(write.config.servers.first?.token, "不要把凭据落进明文文件")
    }

    func testUnreadableKeychainLeavesTheServerUntouched() {
        // Defence in depth (the engine aborts the pass before this point): a failed read
        // must not be mistaken for "no token".
        let merged = SyncDocument(servers: [syncServer(url, token: "legacy-cloud", topics: [syncTopic("alerts")])])
        let write = apply(merged, to: machineLocalConfig(), keychain: .failed)
        XCTAssertNil(write.tokenPlacements[url])
        XCTAssertEqual(write.config.servers.first?.token, "yaml-token")
    }

    func testApplyingTheMergedDocumentIsIdentityForPublishing() {
        let merged = SyncDocument(servers: [syncServer(url, token: "legacy-cloud",
                                                       topics: [syncTopic("alerts", iconSymbol: "bell"), syncTopic("new-from-cloud")])])
        .canonicalized
        let write = apply(merged, to: machineLocalConfig(), keychain: .value("kc-token"))
        let republished = ConfigSyncTranslator.document(from: write.config)

        XCTAssertEqual(republished, merged, "应用合并结果后再导出应一致（令牌不参与同一性），否则同步永不收敛")
        XCTAssertNil(republished.servers.first?.token)
    }
}
