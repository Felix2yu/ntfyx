import Foundation
import Yams

/// Stateless configuration file I/O (audit E3): every operation is a pure function of
/// its arguments and safe to call from any thread. The in-memory source of truth lives
/// in `ConfigStore`; this enum only (de)serializes, validates permissions and creates
/// files on disk.
public enum ConfigFile {
    /// Default configuration path: ~/.config/ntfyx/config.yml
    public static var defaultConfigPath: String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".config/ntfyx/config.yml").path
    }

    /// One successful read of a config file.
    public struct Loaded: Sendable {
        public let config: AppConfig
        public let warning: String?
        /// Exact UTF-8 bytes-as-text of the file; `ConfigStore` uses it to tell its own
        /// writes apart from external edits.
        let raw: String
    }

    /// Yams escapes every non-ASCII scalar unless told otherwise, which would turn a Chinese
    /// `display_name` or action title into `"\u751F\u4EA7..."` on the next save. Both the local
    /// file and the cloud document are meant to stay hand-editable, so scalars go out as UTF-8.
    static func utf8Encoder() -> YAMLEncoder {
        let encoder = YAMLEncoder()
        encoder.options.allowUnicode = true
        return encoder
    }

    /// Reads, permission-checks and decodes the config file at `path`.
    public static func read(from path: String) throws -> Loaded {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ConfigError.fileNotFound
        }

        // Validate file permissions - should not be world-writable
        try validateFilePermissions(at: path)

        let url = URL(fileURLWithPath: path)
        let yamlString: String
        do {
            yamlString = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigError.fileNotFound
        }

        // Validate for unknown keys before decoding (warnings only, doesn't block loading)
        let unknownKeysWarning = checkForUnknownKeys(in: yamlString)

        do {
            let config = try YAMLDecoder().decode(AppConfig.self, from: yamlString)
            return Loaded(config: config, warning: unknownKeysWarning, raw: yamlString)
        } catch {
            throw ConfigError.decodingError(error)
        }
    }

    /// Serializes an AppConfig to YAML and writes it atomically. The previous file is
    /// used as a comment source (audit 2.7 / E3 comment-passthrough policy): Yams has no
    /// comment API, so comments are re-attached line-by-line to content lines whose text
    /// is unchanged; content lines themselves come from the encoder untouched.
    /// - Returns: the exact text written, so callers can recognize their own writes.
    @discardableResult
    public static func write(_ config: AppConfig, to path: String? = nil) throws -> String {
        let configPath = path ?? defaultConfigPath
        let url = URL(fileURLWithPath: configPath)

        // Ensure the directory exists
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let yamlString = try Self.utf8Encoder().encode(config)

        let original = try? String(contentsOf: url, encoding: .utf8)
        let output = ConfigTextMerger.merge(body: yamlString, original: original)

        try output.write(to: url, atomically: true, encoding: .utf8)
        return output
    }

    /// Creates a sample configuration file at the specified path.
    /// Returns false when a file is already there — an existing config is never overwritten.
    @discardableResult
    public static func createSampleConfig(at path: String? = nil) throws -> Bool {
        try writeNewConfig(sampleConfigYAML, at: path)
    }

    /// The documented example `ntfyxctl init` writes. Its servers are placeholders, so the
    /// file is meant to be edited before anything subscribes to it.
    static let sampleConfigYAML = """
        # ntfyx 配置文件
        # local_server_port: 9292  # 可选：启用本地 HTTP 服务器，供脚本触发通知
        servers:
          - url: https://ntfy.sh
            # token: your_token_here  # 可选，或使用 'ntfyxctl auth add' 存入钥匙串
            # allowed_schemes:  # 可选，默认为 [http, https]
            #   - https
            #   - myapp
            # allowed_domains:  # 可选，限制可打开链接的域名
            #   - example.com
            #   - "*.trusted.org"
            topics:
              - name: alerts
                display_name: 生产告警  # 可选，界面上显示的名字；主题 id 只能是英文
                icon_symbol: bell.fill
                # click_url: false  # 禁止点击通知时打开浏览器
                actions:
                  - title: Acknowledge
                    type: script
                    path: /usr/local/bin/ack-alert.sh

              - name: releases
                icon_symbol: arrow.down.circle.fill
                click_url: https://github.com/org/repo/releases  # 点击时打开的自定义链接

          - url: https://your-private-server.com
            token: your_private_token
            topics:
              - name: deployments
                icon_path: /Users/you/icons/deploy.png
                auto_run_script: /usr/local/bin/deploy-handler.sh

              - name: monitoring
                icon_symbol: server.rack
                silent: true
        """

    /// Creates the file a first launch takes over: valid YAML with no subscriptions yet,
    /// so the service starts right away and the user adds topics in Settings.
    /// Returns false when a config already exists — it is never overwritten.
    @discardableResult
    public static func createInitialConfig(at path: String? = nil) throws -> Bool {
        try writeNewConfig(initialConfigYAML, at: path)
    }

    /// Empty on purpose: starting must never subscribe the user to a placeholder server.
    /// The commented block below is the same example `ntfyxctl init` writes.
    static let initialConfigYAML = """
    # ntfyx 配置文件（首次启动自动生成）

    # 订阅在这里的 servers 下配置，也可以点击菜单栏的 ntfyx 图标 → 设置，
    # 保存后立刻生效，不用重启。手写的话照下面的示例来：
    #
    # servers:
    #   - url: https://ntfy.sh
    #     topics:
    #       - name: alerts
    #         icon_symbol: bell.fill
    #   - url: https://your-private-server.com
    #     # token: your_token_here  # 或使用 'ntfyxctl auth add <服务器地址> <令牌>' 存入钥匙串
    #     topics:
    #       - name: deployments
    #         display_name: 部署通知  # 界面上显示的名字，主题 id 只能是英文
    #
    # 更多可选项（运行 'ntfyxctl init' 可生成完整示例文件）：
    #   fetch_missed: true           # 断线重连后补收离线期间的消息
    #   silent: true                 # 静默通知
    #   click_url: https://example.com  # 点击通知打开的链接，false 表示不打开
    #   auto_run_script: /path/to/script.sh
    #   actions: [{title: 确认, type: script, path: /path/to/script.sh}]
    # local_server_port: 9292        # 可选：本地 HTTP 服务，供脚本触发通知

    servers: []
    """

    /// Writes a brand-new config file, creating its directory first. Returns false when
    /// the path is already taken.
    private static func writeNewConfig(_ contents: String, at path: String?) throws -> Bool {
        let configPath = path ?? defaultConfigPath
        let url = URL(fileURLWithPath: configPath)

        if FileManager.default.fileExists(atPath: configPath) {
            return false
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: - Validation

    /// Validates that the config file has secure permissions (not world-writable)
    static func validateFilePermissions(at path: String) throws {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: path)

        guard let posixPermissions = attributes[.posixPermissions] as? Int else {
            return  // Can't determine permissions, allow
        }

        // Check if world-writable (others have write permission: ----w--w-)
        // POSIX permission bits: owner (rwx), group (rwx), others (rwx)
        // World-writable means the last octet has write bit (0o002)
        let worldWritable = (posixPermissions & 0o002) != 0

        if worldWritable {
            throw ConfigError.insecureFilePermissions(
                "配置文件 \(path) 权限过于开放（任意用户可写，权限：\(String(posixPermissions, radix: 8))）。" +
                "请执行：chmod o-w \"\(path)\""
            )
        }
    }

    /// Known keys at each level of the config
    private static let knownRootKeys: Set<String> = ["servers", "local_server_port"]
    private static let knownServerKeys: Set<String> = ["url", "token", "topics", "allowed_schemes", "allowed_domains", "fetch_missed"]
    private static let knownTopicKeys: Set<String> = ["name", "display_name", "icon_path", "icon_symbol", "auto_run_script", "auto_run_script_args", "silent", "click_url", "actions", "fetch_missed"]
    private static let knownActionKeys: Set<String> = ["title", "type", "path", "url", "name", "script", "args"]

    /// Checks YAML for unknown keys that would be silently ignored.
    /// Returns warning message if unknown keys found, nil otherwise.
    static func checkForUnknownKeys(in yamlString: String) -> String? {
        guard let yaml = try? Yams.load(yaml: yamlString) as? [String: Any] else {
            return nil  // Let the decoder handle invalid YAML
        }

        var warnings: [String] = []

        // Check root level
        for key in yaml.keys {
            if !knownRootKeys.contains(key) {
                warnings.append("根级别存在未知配置项 '\(key)'")
            }
        }

        // Check servers
        if let servers = yaml["servers"] as? [[String: Any]] {
            for (serverIndex, server) in servers.enumerated() {
                let serverUrl = server["url"] as? String ?? "server[\(serverIndex)]"
                for key in server.keys {
                    if !knownServerKeys.contains(key) {
                        warnings.append("服务器 '\(serverUrl)' 中存在未知配置项 '\(key)'")
                    }
                }

                // Check topics
                if let topics = server["topics"] as? [[String: Any]] {
                    for (topicIndex, topic) in topics.enumerated() {
                        let topicName = topic["name"] as? String ?? "topic[\(topicIndex)]"
                        for key in topic.keys {
                            if !knownTopicKeys.contains(key) {
                                warnings.append("主题 '\(topicName)'（服务器：\(serverUrl)）中存在未知配置项 '\(key)'")
                            }
                        }

                        // Check actions
                        if let actions = topic["actions"] as? [[String: Any]] {
                            for (actionIndex, action) in actions.enumerated() {
                                let actionTitle = action["title"] as? String ?? "action[\(actionIndex)]"
                                for key in action.keys {
                                    if !knownActionKeys.contains(key) {
                                        warnings.append("动作 '\(actionTitle)'（主题：\(topicName)）中存在未知配置项 '\(key)'")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if warnings.isEmpty {
            return nil
        }
        return warnings.joined(separator: "\n")
    }
}

/// Line-level comment carry-over for `ConfigFile.write`. Comment blocks stick to the
/// next content line in the original file and are re-emitted (re-indented to match)
/// above the same line in the new body; trailing `# …` comments are re-attached the
/// same way. Only comment text is ever inserted — no content line is modified — so the
/// merged document stays as valid as the encoded body.
///
/// This is the deliberate E3 "known keys carry their comment blocks" policy: comments
/// are user documentation attached to unchanged lines, never content the data model
/// has to understand.
enum ConfigTextMerger {
    static let defaultHeader = [
        "# ntfyx configuration",
        "# Edit manually or use Settings in the menu bar",
    ]

    struct CommentGroup: Equatable {
        var lines: [String]      // raw comment/blank lines, original order
        var contentIndent: Int   // indent of the content line they annotate
    }

    struct Parsed {
        var leading: [String] = []                                  // header before the first content line
        var preceding: [String: [CommentGroup]] = [:]               // trimmed content line → comment groups (FIFO)
        var trailingInline: [String: [String]] = [:]                // trimmed content line → " # …" texts (FIFO)
    }

    // MARK: - Parsing the original file

    static func parse(original: String) -> Parsed {
        var parsed = Parsed()
        var pending: [String] = []
        var sawContent = false

        for raw in original.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                pending.append(raw)
                continue
            }
            let (content, inline) = splitInlineComment(raw)
            let key = content.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            let group = trimBlankEdges(pending)
            pending.removeAll()
            if !sawContent {
                parsed.leading = group
            } else if !group.isEmpty {
                parsed.preceding[key, default: []].append(
                    CommentGroup(lines: group, contentIndent: indentOf(raw))
                )
            }
            if let inline {
                parsed.trailingInline[key, default: []].append(inline)
            }
            sawContent = true
        }
        // Trailing comments at EOF annotate nothing further — dropped with the old file.
        return parsed
    }

    /// Splits `key: value  # note` into content and comment at the first `#` that is
    /// outside quotes and preceded by whitespace — the same rule YAML itself applies.
    static func splitInlineComment(_ line: String) -> (content: String, comment: String?) {
        let chars = Array(line)
        var inSingle = false
        var inDouble = false
        var previous: Character?
        for (i, c) in chars.enumerated() {
            switch c {
            case "'": if !inDouble { inSingle.toggle() }
            case "\"": if !inSingle, previous != "\\" { inDouble.toggle() }
            case "#":
                if !inSingle, !inDouble, i > 0, chars[i - 1] == " " || chars[i - 1] == "\t" {
                    let content = String(chars[0..<i])
                    let comment = String(chars[i...]).trimmingCharacters(in: .whitespaces)
                    return (content, comment)
                }
            default: break
            }
            previous = c
        }
        return (line, nil)
    }

    // MARK: - Merging into the new body

    static func merge(body: String, original: String?) -> String {
        let parsed = original.map { parse(original: $0) } ?? Parsed()
        var remainingGroups = parsed.preceding
        var remainingInline = parsed.trailingInline

        var out: [String] = []
        var wroteContent = false
        for raw in body.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                out.append(raw)
                continue
            }
            if !wroteContent {
                wroteContent = true
                out.append(contentsOf: parsed.leading.isEmpty ? defaultHeader : parsed.leading)
                out.append("")
            }
            if let groups = remainingGroups[trimmed], let group = groups.first {
                popFirst(&remainingGroups, trimmed)
                out.append(contentsOf: reindent(group, to: indentOf(raw)))
            }
            var line = raw
            if let trailings = remainingInline[trimmed], let comment = trailings.first {
                popFirst(&remainingInline, trimmed)
                line = raw + "  " + comment
            }
            out.append(line)
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func popFirst<Value>(_ dict: inout [String: [Value]], _ key: String) {
        var values = dict[key] ?? []
        if !values.isEmpty { values.removeFirst() }
        if values.isEmpty { dict[key] = nil } else { dict[key] = values }
    }

    /// Keeps each comment line's indentation *relative to its content line*, shifted to
    /// the new indent, so a block that sat over an indented `- name:` still reads right.
    private static func reindent(_ group: CommentGroup, to newIndent: Int) -> [String] {
        group.lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return "" }
            let relative = max(indentOf(line) - group.contentIndent, 0)
            return String(repeating: " ", count: newIndent + relative) + trimmed
        }
    }

    private static func indentOf(_ line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" }).count
    }

    private static func trimBlankEdges(_ lines: [String]) -> [String] {
        var lines = lines[...]
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines = lines.dropFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines = lines.dropLast() }
        return Array(lines)
    }
}
