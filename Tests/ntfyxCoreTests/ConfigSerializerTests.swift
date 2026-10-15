import XCTest
import Yams
@testable import NtfyxCore

/// Audit 2.7: saving from Settings used to dump the whole YAML and drop every comment.
/// The merger re-attaches comment blocks and inline notes to content lines whose text
/// survived the rewrite.
@MainActor
final class ConfigSerializerTests: XCTestCase {

    // MARK: - Pure merge behaviour

    func testBlockCommentsReattachToTheirContentLines() {
        let original = """
        # my doc header
        # line two
        servers:
          # first box
          - url: https://a.example
          # second box
          - url: https://b.example

        """
        let body = """
        servers:
        - url: https://a.example
        - url: https://b.example
        """
        let merged = ConfigTextMerger.merge(body: body, original: original)
        let lines = merged.components(separatedBy: "\n")

        XCTAssertEqual(lines.first, "# my doc header")
        XCTAssertEqual(lines[1], "# line two")
        // Comments return re-indented to their content line's new depth.
        guard let aIndex = lines.firstIndex(of: "- url: https://a.example") else {
            return XCTFail("content line missing:\n\(merged)")
        }
        XCTAssertEqual(lines[aIndex - 1], "# first box")
        guard let bIndex = lines.firstIndex(of: "- url: https://b.example") else {
            return XCTFail("content line missing:\n\(merged)")
        }
        XCTAssertEqual(lines[bIndex - 1], "# second box")
    }

    func testRelativeCommentIndentationFollowsContent() {
        let original = """
        servers:
          - url: https://a.example
              # deep note
          - url: https://b.example
        """
        let body = """
        servers:
        - url: https://a.example
        - url: https://b.example
        """
        let merged = ConfigTextMerger.merge(body: body, original: original)
        let lines = merged.components(separatedBy: "\n")
        guard let bIndex = lines.firstIndex(of: "- url: https://b.example") else {
            return XCTFail("content line missing:\n\(merged)")
        }
        // The note sat 4 columns deeper than its content line (6 vs 2) → keep the depth.
        XCTAssertEqual(lines[bIndex - 1], "    # deep note")
    }

    func testInlineCommentsKeptOnUnchangedLines() {
        let original = """
        servers:
          - url: https://a.example
            token: tk  # from the vault
        """
        let body = """
        servers:
        - url: https://a.example
          token: tk
        """
        let merged = ConfigTextMerger.merge(body: body, original: original)
        XCTAssertTrue(merged.contains("token: tk  # from the vault"), merged)
    }

    func testHashInsideQuotesIsNotTreatedAsComment() {
        let (content, comment) = ConfigTextMerger.splitInlineComment(#"click: "https://a.example/#anchor""#)
        XCTAssertNil(comment)
        XCTAssertEqual(content.trimmingCharacters(in: .whitespaces), #"click: "https://a.example/#anchor""#)
    }

    func testDefaultHeaderOnlyWhenOriginalHadNoLeadingComments() {
        let body = "servers:\n- url: https://a.example\n"
        let fresh = ConfigTextMerger.merge(body: body, original: nil)
        XCTAssertTrue(fresh.hasPrefix(ConfigTextMerger.defaultHeader.joined(separator: "\n")))

        let bare = ConfigTextMerger.merge(body: body, original: "servers:\n  - url: https://a.example\n")
        XCTAssertTrue(bare.hasPrefix(ConfigTextMerger.defaultHeader.joined(separator: "\n")))

        let commented = ConfigTextMerger.merge(body: body, original: "# mine\nservers:\n")
        XCTAssertTrue(commented.hasPrefix("# mine"))
        XCTAssertFalse(commented.contains("Edit manually"))
    }

    func testCommentsOfRemovedAndChangedLinesAreDropped() {
        let original = """
        # header
        servers:
          # stays
          - url: https://a.example
          # gone with the server
          - url: https://c.example
        """
        let body = """
        servers:
        - url: https://a.example
        - url: https://b.example
        """
        let merged = ConfigTextMerger.merge(body: body, original: original)
        XCTAssertTrue(merged.contains("# stays"))
        XCTAssertFalse(merged.contains("gone with the server"))
    }

    // MARK: - saveConfig round-trip

    func testSaveConfigRoundTripPreservesCommentsAndContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfy-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("config.yml").path

        let originalText = """
        # ntfyx 配置文件
        servers:
          # 家里的小盒子
          - url: https://a.example
            token: tk  # 明文令牌
            topics:
              - name: alerts  # 告警频道
                silent: true
        """
        try originalText.write(toFile: path, atomically: true, encoding: .utf8)

        let decoded = try YAMLDecoder().decode(AppConfig.self, from: originalText)
        try ConfigFile.write(decoded, to: path)

        let saved = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(saved.contains("# ntfyx 配置文件"), saved)
        XCTAssertTrue(saved.contains("# 家里的小盒子"), saved)
        XCTAssertTrue(saved.contains("# 明文令牌"), saved)
        XCTAssertTrue(saved.contains("# 告警频道"), saved)

        // The merged file must still be valid and mean exactly the same thing.
        let reloaded = try YAMLDecoder().decode(AppConfig.self, from: saved)
        XCTAssertEqual(reloaded.servers.count, 1)
        XCTAssertEqual(reloaded.servers[0].url, "https://a.example")
        XCTAssertEqual(reloaded.servers[0].token, "tk")
        XCTAssertEqual(reloaded.servers[0].topics.map(\.name), ["alerts"])
        XCTAssertEqual(reloaded.servers[0].topics[0].silent, true)
    }

    // MARK: - Active path (serve --config must not bleed into the default file)

    func testLoadConfigRecordsActivePathAndSaveFallbackWritesThere() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfy-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("config.yml").path

        let originalText = """
        # 自定义路径配置
        servers:
          - url: https://a.example
            topics:
              - name: alerts
        """
        try originalText.write(toFile: path, atomically: true, encoding: .utf8)

        let store = ConfigStore()
        try store.load(from: path)
        XCTAssertEqual(store.activePath, path)

        // A reload without an explicit path must re-read the same file, not the default one.
        let edited = originalText.replacingOccurrences(of: "name: alerts", with: "name: other")
        try edited.write(toFile: path, atomically: true, encoding: .utf8)
        try store.reloadFromDisk()
        XCTAssertEqual(store.config?.servers.first?.topics.map(\.name), ["other"])

        // save without a path writes to the active file, keeping its comments.
        try store.save(store.config!)
        let saved = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(saved.contains("# 自定义路径配置"), saved)
        XCTAssertTrue(saved.contains("name: other"), saved)
        XCTAssertNotEqual(store.activePath, ConfigStore.defaultConfigPath)
    }

    // MARK: - 中文备注 survives a save

    func testChineseDisplayNameIsWrittenBackVerbatimWithItsComments() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-cn-\(UUID().uuidString).yml").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let original = """
        # 我的订阅
        servers:
          - url: https://a.example
            topics:
              - name: alerts  # 服务器上建的英文主题
                display_name: 生产告警
        """
        try original.write(toFile: path, atomically: true, encoding: .utf8)

        let store = ConfigStore()
        try store.load(from: path)
        XCTAssertEqual(store.config?.servers.first?.topics.first?.label, "生产告警")

        try store.save(store.config!)
        let saved = try String(contentsOfFile: path, encoding: .utf8)

        // Yams must not escape the Chinese value into \uXXXX, or the file stops being editable.
        XCTAssertTrue(saved.contains("display_name: 生产告警"), saved)
        XCTAssertFalse(saved.contains("\\u"), saved)
        XCTAssertTrue(saved.contains("# 我的订阅"), saved)
        XCTAssertTrue(saved.contains("# 服务器上建的英文主题"), saved)
    }

    // MARK: - Shipped sample files

    /// `ntfyxctl init` writes this verbatim, so it has to decode — and the commented block in
    /// the first-launch file is what a user copies by hand.
    func testSampleAndInitialConfigsDecode() throws {
        let sample = try YAMLDecoder().decode(AppConfig.self, from: ConfigFile.sampleConfigYAML)
        XCTAssertEqual(sample.servers.count, 2)
        XCTAssertEqual(sample.servers[0].topics.first?.label, "生产告警")
        XCTAssertEqual(sample.servers[0].topics.first?.name, "alerts")
        XCTAssertNil(ConfigFile.checkForUnknownKeys(in: ConfigFile.sampleConfigYAML))

        let initial = try YAMLDecoder().decode(AppConfig.self, from: ConfigFile.initialConfigYAML)
        XCTAssertTrue(initial.servers.isEmpty)
        XCTAssertEqual(initial.allTopics.count, 0)
    }

    // MARK: - Unknown key whitelist

    func testSupportedTopicAndActionKeysDoNotWarn() {
        let yaml = """
        servers:
          - url: https://a.example
            topics:
              - name: alerts
                display_name: 生产告警
                auto_run_script: /bin/true
                auto_run_script_args: ["--fast"]
                actions:
                  - title: 处理
                    type: script
                    path: /bin/true
                    args: ["--now"]
        """
        XCTAssertNil(ConfigFile.checkForUnknownKeys(in: yaml))
    }

    func testTypoInTopicKeyStillWarns() {
        let yaml = """
        servers:
          - url: https://a.example
            topics:
              - name: alerts
                display_name: 生产告警
                icon_symbol: bell
                auto_run_script: /bin/true
                auto_run_script_args: ["--fast"]
                actions:
                  - title: 处理
                    type: script
                    path: /bin/true
                    args: ["--now"]
                iconpath: /bin/icon.png
        """
        let warning = ConfigFile.checkForUnknownKeys(in: yaml)
        XCTAssertTrue(warning?.contains("iconpath") ?? false, warning ?? "no warning emitted")
    }
}
