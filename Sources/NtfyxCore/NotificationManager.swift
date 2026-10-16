import Foundation
import CryptoKit
import UserNotifications
import AppKit

/// All notification delivery lives on the main actor: UNUserNotificationCenter and its
/// delegate are main-queue APIs, and the banner/category memo state used to be guarded by
/// several NSLocks whose callbacks escaped to socket queues (audit B1).
@MainActor
public final class NotificationManager: NSObject {
    public static let shared = NotificationManager()

    private lazy var center: UNUserNotificationCenter = {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    private var _scriptRunner: (any ScriptRunnerProtocol)?

    /// Config lookups injected by the running coordinator (audit E3); the manager never
    /// reaches for a configuration singleton itself. Both run on the main actor.
    private var serverConfigLookup: ((String) -> ServerConfig?)?
    private var topicConfigLookup: ((String, String) -> TopicConfig?)?

    func setConfigLookup(
        server: @escaping (String) -> ServerConfig?,
        topic: @escaping (String, String) -> TopicConfig?
    ) {
        serverConfigLookup = server
        topicConfigLookup = topic
    }

    private func serverConfig(for serverBaseURL: String) -> ServerConfig? {
        serverConfigLookup?(serverBaseURL)
    }

    private func topicConfig(serverBaseURL: String, topic: String) -> TopicConfig? {
        topicConfigLookup?(serverBaseURL, topic)
    }

    /// The name a topic is shown under in a banner: the user's 备注 when this server has one.
    private func bannerLabel(for topic: String, serverURL: String?) -> String {
        guard let serverURL, let config = topicConfig(serverBaseURL: serverURL, topic: topic) else {
            return topic
        }
        return config.label
    }

    /// Icons and action categories describe a topic, not a message, but both used to be
    /// rebuilt for every banner: the SF Symbol round trip (TIFF → PNG) per message, and a
    /// `getNotificationCategories` + `setNotificationCategories` pair — two XPC calls plus a copy
    /// of the whole registered set — per message too. Memoizing by shape means the render happens
    /// once per distinct symbol and the registration once per distinct action set.
    private var _iconPNG: [String: Data] = [:]
    private var _iconRenderFailures: Set<String> = []
    private var _iconsDirectoryReady = false
    private var _registeredCategoryKeys: Set<String> = []

    private let throttle = NotificationThrottle()

    /// Single banner that replaces the flood while a message storm is in progress.
    nonisolated static let burstSummaryIdentifier = "ntfy:burst-summary"

    /// How ntfy's message priority decides banner delivery, mirroring the mobile
    /// clients: 1 (min) never interrupts, 2 (low) arrives quietly.
    enum PriorityHandling: Equatable {
        case suppressed   // priority <= 1: history only, no banner at all
        case passive      // priority == 2: banner without sound, outside the burst throttle
        case normal
    }

    nonisolated static func priorityHandling(for priority: Int?) -> PriorityHandling {
        switch priority ?? 3 {
        case ...1: return .suppressed
        case 2: return .passive
        default: return .normal
        }
    }

    private override init() {
        super.init()
        // Don't call clearCategories() here - it accesses UNUserNotificationCenter
        // which requires the run loop to be active
    }

    /// Clears all notification categories to remove stale actions
    func clearCategories() {
        center.setNotificationCategories([])
        // The memo has to go with them: an emptied Notification Center is not "already
        // registered", and the next banner of a known shape would otherwise arrive without
        // its buttons.
        _registeredCategoryKeys.removeAll()
        Log.info("Cleared notification categories")
    }

    /// Sets the script runner - accepts protocol for DI/testing
    func setScriptRunner(_ runner: any ScriptRunnerProtocol) {
        self._scriptRunner = runner
    }

    private var scriptRunner: (any ScriptRunnerProtocol)? {
        _scriptRunner
    }

    /// Requests notification permissions from the user. Only a `.notDetermined` status
    /// presents the system dialog; an already-decided status returns the current result.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        guard status == .notDetermined else {
            if status == .authorized {
                Log.info("Notification permissions already granted")
            } else {
                Log.error("Notification permissions are currently denied or restricted")
                Log.info("   Please enable notifications in System Settings → Notifications → ntfyx")
            }
            return status == .authorized
        }

        Log.info("Requesting notification permission...")
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                Log.success("Permission granted!")
            } else {
                Log.error("Notification permission not granted")
                Log.info("   Please enable notifications in System Settings → Notifications → ntfyx")
            }
            return granted
        } catch {
            Log.error("Notification permission request failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Current notification authorization status.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: - Banner identity

    /// Delivered notifications are keyed by the ntfy message id rather than a random UUID,
    /// so a message read or deleted on *any* device can be traced back to its banner.
    nonisolated static func identifier(forMessageID messageID: String) -> String {
        "ntfy:\(messageID)"
    }

    /// User Notifications aborts the process (`bundleProxyForCurrentProcess is nil`) unless
    /// the executable runs out of an app bundle, which is also the only case where there can
    /// be banners to talk about.
    nonisolated static var canManageBanners: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Withdraws the banners these messages left on screen — used when the message gets
    /// marked read or deleted, here or on another device.
    func revoke(messageIDs: [String]) {
        let identifiers = messageIDs
            .filter { !$0.isEmpty }
            .map { Self.identifier(forMessageID: $0) }
        guard !identifiers.isEmpty, Self.canManageBanners else { return }

        Log.info("Revoking \(identifiers.count) notification(s): \(messageIDs.joined(separator: ", "))")
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// Displays a notification based on an ntfy message and topic configuration.
    /// During a message storm, individual banners are folded into one summary notification —
    /// hundreds of sound-bearing banners in a few seconds freeze notification center and its
    /// sound queue survives app exit.
    /// - Parameter serverURL: base URL of the server the message arrived on; the topic
    ///   config is resolved per (server, topic) because the same name can exist on several servers.
    func showNotification(for message: NtfyMessage, topicConfig: TopicConfig?, serverURL: String? = nil) {
        // Menu-bar pause suppresses every banner path, and returns before the throttle
        // registers the message: a paused catch-up must not ignite a burst summary
        // on resume.
        if NotificationPause.shared.isPaused {
            Log.info("Notifications paused: suppressing banner for \(message.topic)/\(message.id)")
            return
        }

        // Skip notification if silent mode is enabled
        if topicConfig?.silent == true {
            Log.info("Silent notification for topic \(message.topic) - skipping display")
            return
        }

        // Priority 1/2 messages are delivered passively (audit 1.5): they never join
        // the burst throttle, so a low-priority catch-up cannot inflate the summary.
        switch Self.priorityHandling(for: message.priority) {
        case .suppressed:
            Log.info("Min-priority message suppressed: \(message.topic)/\(message.id)")
            return
        case .passive:
            if let topicConfig {
                showTopicNotification(for: message, topicConfig: topicConfig, serverURL: serverURL, passive: true)
            } else {
                showBasicNotification(for: message, passive: true)
            }
            return
        case .normal:
            break
        }

        let identifier = Self.identifier(forMessageID: message.id)
        switch throttle.register(topic: message.topic, priority: message.priority, identifier: identifier) {
        case .individual:
            if let topicConfig {
                showTopicNotification(for: message, topicConfig: topicConfig, serverURL: serverURL)
            } else {
                showBasicNotification(for: message)
            }
        case .coalesced(let count, let topics, let firstOfBurst, let absorbed):
            // The storm banner names topics, so it names them the way the user did.
            let labels = topics.map { bannerLabel(for: $0, serverURL: serverURL) }
            showBurstSummary(count: count, topics: labels, firstOfBurst: firstOfBurst, absorbed: absorbed)
        }
    }

    /// One replaceable banner for the whole storm. The sound plays only when the burst
    /// starts; each later message replaces the summary in place, updating the count.
    /// When the burst begins it also withdraws the individual banners that slipped out
    /// during the ramp-up, so the storm leaves a single trace in notification center.
    private func showBurstSummary(count: Int, topics: [String], firstOfBurst: Bool, absorbed: [String]) {
        guard Self.canManageBanners else { return }

        if !absorbed.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: absorbed)
        }

        let content = UNMutableNotificationContent()
        content.title = LF("%d 条新消息", count)
        let shownTopics = topics.prefix(3).joined(separator: "、")
        if topics.count > 3 {
            content.body = LF("消息过于集中，已合并显示：%1$@ 等 %2$d 个主题", shownTopics, topics.count)
        } else {
            content.body = LF("消息过于集中，已合并显示：%@", shownTopics)
        }
        content.interruptionLevel = .active
        if firstOfBurst {
            content.sound = UNNotificationSound(named: UNNotificationSoundName("Glass.aiff"))
        }

        let request = UNNotificationRequest(
            identifier: Self.burstSummaryIdentifier,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error = error {
                Log.error("Failed to show burst summary notification: \(error)")
            }
        }
    }

    /// One replaceable banner for a whole replayed catch-up. The messages are old by
    /// definition — the server sent them from its cache — so they are one event worth
    /// reporting, not hundreds of sound-bearing banners.
    nonisolated static let catchUpSummaryIdentifier = "ntfy:catch-up-summary"

    func showCatchUpSummary(count: Int, topics: [String]) {
        guard count > 0, Self.canManageBanners else { return }

        let content = UNMutableNotificationContent()
        content.title = LF("补齐 %d 条消息", count)
        let shownTopics = topics.prefix(3).joined(separator: "、")
        if topics.count > 3 {
            content.body = LF("已收录历史：%1$@ 等 %2$d 个主题", shownTopics, topics.count)
        } else {
            content.body = LF("已收录历史：%@", shownTopics)
        }
        content.interruptionLevel = .active
        content.sound = UNNotificationSound(named: UNNotificationSoundName("Glass.aiff"))

        let request = UNNotificationRequest(
            identifier: Self.catchUpSummaryIdentifier,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error = error {
                Log.error("Failed to show catch-up summary notification: \(error)")
            }
        }
    }

    /// Banner title for a message. A message with no title of its own is named by its
    /// topic — under the name the user gave it, not the server's ASCII id.
    nonisolated static func bannerTitle(for message: NtfyMessage, topicLabel: String) -> String {
        let emojiPrefix = EmojiTags.emojiPrefix(for: message.tags)
        if let title = message.plainTextTitle ?? message.title, !title.isEmpty {
            return emojiPrefix + title
        }
        return emojiPrefix + topicLabel
    }

    /// Banner body for a message. Notification Center clips a long body to the first few lines
    /// and shows no ellipsis, so a paragraph break that lands on the last visible line leaves the
    /// box with an empty bottom row — unlike every other app. A banner gets one text line per line.
    nonisolated static func bannerBody(for message: NtfyMessage, fallback: String = "") -> String {
        let text = message.plainTextMessage ?? message.message ?? fallback
        return text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }

    private func showTopicNotification(for message: NtfyMessage, topicConfig: TopicConfig, serverURL: String?, passive: Bool = false) {
        let content = UNMutableNotificationContent()
        // Use plain text versions to strip markdown syntax (macOS notifications don't render markdown)
        content.title = Self.bannerTitle(for: message, topicLabel: topicConfig.label)
        content.body = Self.bannerBody(for: message, fallback: topicConfig.label)
        if passive {
            content.interruptionLevel = .passive
            content.sound = nil
        } else {
            // Use Glass sound to distinguish from other notification services
            content.sound = UNNotificationSound(named: UNNotificationSoundName("Glass.aiff"))
        }

        // Map ntfy priority to interruption levels
        if !passive, let priority = message.priority {
            switch priority {
            case 5:
                content.interruptionLevel = .critical
                content.sound = .defaultCritical
            case 4:
                content.interruptionLevel = .timeSensitive
            default:
                content.interruptionLevel = .active
            }
        }

        if let attachment = createIconAttachment(from: topicConfig) {
            content.attachments = [attachment]
        }

        // Determine click URL. Priority order:
        // 1. `click_url` from topic config (`false`, custom URL)
        // 2. `click` URL from the message itself
        // 3. Default server URL
        let clickUrl: String
        let isCustomClickUrl: Bool

        switch topicConfig.clickUrl {
        case .custom(let customUrl):
            // 1. Highest priority: custom URL from config
            clickUrl = customUrl
            isCustomClickUrl = true
        case .disabled:
            // 1. Highest priority: disabled from config
            clickUrl = ""
            isCustomClickUrl = false // Not applicable
        case .enabled, .none:
            // Config doesn't specify an override, so check the message
            if let messageClickUrl = message.click, !messageClickUrl.isEmpty {
                // 2. Next priority: URL from the message
                clickUrl = messageClickUrl
                isCustomClickUrl = true
            } else {
                // 3. Fallback: default server URL
                clickUrl = serverURL ?? ""
                isCustomClickUrl = false
            }
        }

        var userInfo: [String: Any] = [
            "messageBody": message.message ?? "",
            "topic": message.topic,
            "serverUrl": clickUrl,
            "isCustomClickUrl": isCustomClickUrl,
            "messageId": message.id
        ]
        // Which subscription delivered this message — topic config and URL
        // allow-lists are scoped to (server, topic), not to the name alone.
        if let serverURL {
            userInfo["serverBaseURL"] = serverURL
        }

        // Handle actions: config actions override message actions
        if let actions = topicConfig.actions, !actions.isEmpty {
            // Config actions take priority - use them instead of message actions
            let categoryId = "topic-\(message.topic)-actions"
            registerCategory(
                identifier: categoryId,
                actions: actions.prefix(4).map { action in
                    UNNotificationAction(
                        identifier: "action-\(action.title.lowercased().replacingOccurrences(of: " ", with: "-"))",
                        title: action.title,
                        options: [.foreground]
                    )
                }
            )
            content.categoryIdentifier = categoryId
            Log.info("Using \(actions.count) actions from config for topic \(message.topic)")
        } else if let messageActions = message.actions, !messageActions.isEmpty {
            // No config actions - use message actions
            let categoryId = Self.messageActionCategoryID(messageActions)
            registerCategory(
                identifier: categoryId,
                actions: messageActions.prefix(4).enumerated().map { (index, action) in
                    UNNotificationAction(
                        identifier: "ntfy-action-\(index)",
                        title: action.label,
                        options: [.foreground]
                    )
                }
            )
            content.categoryIdentifier = categoryId

            // Store action URLs, types, and HTTP details in userInfo for later retrieval
            var actionUrls: [String: String] = [:]
            var actionTypes: [String: String] = [:]
            var actionDetailsJson: [String: String] = [:]
            for (index, action) in messageActions.enumerated() {
                let key = "ntfy-action-\(index)"
                if let url = action.url {
                    actionUrls[key] = url
                }
                actionTypes[key] = action.action
                if action.action == "http" {
                    var details: [String: Any] = [:]
                    details["method"] = action.method ?? "POST"
                    details["url"] = action.url ?? ""
                    if let body = action.body {
                        details["body"] = body
                    }
                    if let headers = action.headers {
                        details["headers"] = headers
                    }
                    // Serialize as JSON string for plist compatibility
                    if let data = try? JSONSerialization.data(withJSONObject: details),
                       let json = String(data: data, encoding: .utf8) {
                        actionDetailsJson[key] = json
                    }
                }
            }
            userInfo["actionUrls"] = actionUrls
            userInfo["actionTypes"] = actionTypes
            userInfo["actionDetailsJson"] = actionDetailsJson
            Log.info("Using \(messageActions.count) actions from message for topic \(message.topic)")
        }

        content.userInfo = userInfo

        // Create and schedule notification
        let request = UNNotificationRequest(
            identifier: Self.identifier(forMessageID: message.id),
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error = error {
                Log.error("Failed to show notification: \(error)")
            }
        }
    }

    /// Shows a basic notification without topic configuration
    private func showBasicNotification(for message: NtfyMessage, passive: Bool = false) {
        let content = UNMutableNotificationContent()
        let emojiPrefix = EmojiTags.emojiPrefix(for: message.tags)
        // Use plain text versions to strip markdown syntax (macOS notifications don't render markdown)
        content.title = emojiPrefix + (message.plainTextTitle ?? message.title ?? "ntfyx")
        content.body = Self.bannerBody(for: message)
        if passive {
            content.interruptionLevel = .passive
            content.sound = nil
        } else {
            // Use Glass sound to distinguish from other notification services
            content.sound = UNNotificationSound(named: UNNotificationSoundName("Glass.aiff"))
        }

        let request = UNNotificationRequest(
            identifier: Self.identifier(forMessageID: message.id),
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error = error {
                Log.error("Failed to show notification: \(error)")
            }
        }
    }

    /// Creates an icon attachment from the topic configuration
    private func createIconAttachment(from topicConfig: TopicConfig) -> UNNotificationAttachment? {
        // Try SF Symbol first — the same symbol renders identically, so one round trip per name
        if let symbolName = topicConfig.iconSymbol, let symbolImage = createSFSymbolImage(named: symbolName) {
            return iconAttachment(symbolName: symbolName, image: symbolImage)
        }

        // Try local file path
        if let iconPath = topicConfig.iconPath {
            let url = URL(fileURLWithPath: iconPath)
            if FileManager.default.fileExists(atPath: iconPath) {
                do {
                    return try UNNotificationAttachment(identifier: UUID().uuidString, url: url, options: nil)
                } catch {
                    Log.error("Failed to create icon attachment from path \(iconPath): \(error)")
                }
            }
        }

        return nil
    }

    /// The symbol *render* is memoized; the attachment is built per message. Notification Center
    /// moves an attachment's file into its own store when the request is added, so a cached
    /// attachment points at a path that stops existing right after the first banner, and every
    /// later one fails with `UNErrorDomain 104` and shows nothing. A failed conversion is
    /// remembered too, so a bad symbol name is not retried per message; the file-path icon stays
    /// uncached because its contents can change.
    private func iconAttachment(symbolName: String, image: NSImage) -> UNNotificationAttachment? {
        let pngData: Data
        if let cached = _iconPNG[symbolName] {
            pngData = cached
        } else if _iconRenderFailures.contains(symbolName) {
            return nil
        } else if let rendered = Self.pngData(for: image) {
            _iconPNG[symbolName] = rendered
            pngData = rendered
        } else {
            _iconRenderFailures.insert(symbolName)
            return nil
        }

        if !_iconsDirectoryReady {
            try? FileManager.default.createDirectory(at: Self.iconCacheDirectory, withIntermediateDirectories: true)
            _iconsDirectoryReady = true
        }
        let fileURL = Self.iconCacheDirectory.appendingPathComponent(Self.iconFileName(for: symbolName))
        do {
            try pngData.write(to: fileURL, options: .atomic)
            return try UNNotificationAttachment(identifier: "icon", url: fileURL, options: nil)
        } catch {
            Log.error("Failed to write SF Symbol attachment: \(error)")
            return nil
        }
    }

    /// Creates an NSImage from an SF Symbol
    private func createSFSymbolImage(named symbolName: String) -> NSImage? {
        // Tinted, because a symbol is a template image: rasterized unstyled it is solid black,
        // which disappears on a dark notification background.
        let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor]))
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private nonisolated static func pngData(for image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    nonisolated static func iconFileName(for symbolName: String) -> String {
        let safeName = symbolName.map {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_"
        }
        return String(safeName) + ".png"
    }

    private nonisolated static let iconCacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("ntfyx/icons", isDirectory: true)
    }()

    /// Identifier shared by every message whose notification buttons look the same. The
    /// buttons resolve their URLs and types from each notification's own userInfo, so the
    /// category only has to describe the labels — keying it by message id registered one new
    /// category per message and never removed any, so the set Notification Center holds grew
    /// without bound.
    nonisolated static func messageActionCategoryID(_ actions: [NtfyMessage.NtfyAction]) -> String {
        let shape = actions.prefix(4).map { "\($0.action):\($0.label)" }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(shape.utf8))
        return "msg-actions-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Registers a category unless this identifier + action set has already been registered:
    /// the get/set pair is two XPC calls plus a copy of the entire registered set, and every
    /// banner of a topic asks for exactly the same one.
    private func registerCategory(identifier: String, actions: [UNNotificationAction]) {
        let key = identifier + "|" + actions.map { "\($0.identifier)=\($0.title)" }.joined(separator: ",")
        let seen = _registeredCategoryKeys.contains(key)
        if !seen { _registeredCategoryKeys.insert(key) }
        guard !seen else { return }

        let category = UNNotificationCategory(
            identifier: identifier,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )

        // The XPC round trip stays off the calling path; the task inherits the main actor,
        // which is where the non-Sendable category value is allowed to live.
        Task {
            // Remove any existing category with the same ID before inserting
            // (Set.insert won't replace, so we must remove first)
            var categories = await center.notificationCategories()
            categories = categories.filter { $0.identifier != identifier }
            categories.insert(category)
            center.setNotificationCategories(categories)
        }
    }

    /// Executes an HTTP action from an ntfy message payload
    private func executeHttpAction(url: URL, details: [String: Any]) {
        let method = (details["method"] as? String)?.uppercased() ?? "POST"
        var request = URLRequest(url: url)
        request.httpMethod = method

        if let headers = details["headers"] as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        if let body = details["body"] as? String {
            request.httpBody = body.data(using: .utf8)
        }

        Log.info("Executing HTTP \(method) action: \(url.absoluteString)")

        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse {
                    Log.info("HTTP action completed with status: \(httpResponse.statusCode)")
                }
            } catch {
                Log.error("HTTP action failed: \(error.localizedDescription)")
            }
        }
    }

    /// Opens a URL securely by validating its scheme and domain against the allowed values in server config
    /// - Parameters:
    ///   - url: The URL to open
    ///   - serverBaseURL: base URL of the server that delivered the message — the same topic
    ///     name can exist on several servers, so the allow-list must come from the right one
    private func openUrlSecurely(_ url: URL, serverBaseURL: String?) {
        let serverConfig = serverBaseURL.flatMap { serverConfig(for: $0) }

        // Validate scheme
        let isSchemeAllowed = serverConfig?.isSchemeAllowed(url) ?? ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        guard isSchemeAllowed else {
            let allowedSchemes = serverConfig?.effectiveAllowedSchemes ?? ["http", "https"]
            Log.info("Refusing to open URL with untrusted scheme: \(url.scheme ?? "nil") (\(url.absoluteString)). Allowed schemes: \(allowedSchemes)")
            return
        }

        // Validate domain
        let isDomainAllowed = serverConfig?.isDomainAllowed(url) ?? true
        guard isDomainAllowed else {
            let allowedDomains = serverConfig?.allowedDomains ?? []
            Log.info("Refusing to open URL with untrusted domain: \(url.host ?? "nil") (\(url.absoluteString)). Allowed domains: \(allowedDomains)")
            return
        }

        Log.info("Opening URL: \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    public func showTestNotification(topic: String) {
        let content = UNMutableNotificationContent()
        content.title = L("测试通知")
        content.body = LF("主题 %@ 的测试通知", topic)
        content.sound = .default

        // The app icon on the left side of the notification is automatically
        // taken from the app bundle's CFBundleIconFile by macOS

        let identifier = UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        center.add(request) { error in
            if let error = error {
                Log.error("Failed to show test notification: \(error)")
            }
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Sendable distillation of a tapped notification: `UNNotificationResponse` and its
    /// `userInfo` ([AnyHashable: Any]) are not Sendable, but the delegate callback arrives
    /// on a background queue, so everything the main-actor handlers need is extracted here,
    /// synchronously, before the hop.
    private struct NotificationAction: Sendable {
        var actionIdentifier: String
        var messageBody: String
        var topic: String
        var clickURL: String
        var isCustomClickURL: Bool
        var serverBaseURL: String?
        var actionTypes: [String: String]
        var actionDetailsJSON: [String: String]
        var actionURLs: [String: String]
    }

    nonisolated private static func makeAction(from response: UNNotificationResponse) -> NotificationAction {
        let userInfo = response.notification.request.content.userInfo
        return NotificationAction(
            actionIdentifier: response.actionIdentifier,
            messageBody: userInfo["messageBody"] as? String ?? "",
            topic: userInfo["topic"] as? String ?? "",
            clickURL: userInfo["serverUrl"] as? String ?? "",
            isCustomClickURL: userInfo["isCustomClickUrl"] as? Bool ?? false,
            serverBaseURL: userInfo["serverBaseURL"] as? String,
            actionTypes: userInfo["actionTypes"] as? [String: String] ?? [:],
            actionDetailsJSON: userInfo["actionDetailsJson"] as? [String: String] ?? [:],
            actionURLs: userInfo["actionUrls"] as? [String: String] ?? [:]
        )
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // No `.badge` here: the Dock badge is the unread count from the history store, and
        // letting Notification Center increment it too would show a number nobody recognises.
        completionHandler([.banner, .sound])
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // UserNotifications delivers this on a background queue; extract the Sendable
        // payload first, then hop to the main actor where all handling lives.
        let action = Self.makeAction(from: response)
        Task { @MainActor in
            self.handle(action)
        }
        completionHandler()
    }

    private func handle(_ action: NotificationAction) {
        if action.actionIdentifier == UNNotificationDefaultActionIdentifier {
            // User clicked on the notification itself - open web view
            openNotificationInWeb(action)
        } else if action.actionIdentifier != UNNotificationDismissActionIdentifier {
            handleActionResponse(action)
        }
    }

    private func openNotificationInWeb(_ action: NotificationAction) {
        guard !action.clickURL.isEmpty else { return }

        // If custom URL, use it directly; otherwise append topic to server URL
        let webUrlString = action.isCustomClickURL ? action.clickURL : "\(action.clickURL)/\(action.topic)"
        if let url = URL(string: webUrlString) {
            openUrlSecurely(url, serverBaseURL: action.serverBaseURL)
        }
    }

    private func handleActionResponse(_ action: NotificationAction) {
        let actionIdentifier = action.actionIdentifier

        // Check for ntfy message actions
        if actionIdentifier.hasPrefix("ntfy-action-") {
            let actionType = action.actionTypes[actionIdentifier] ?? "view"

            if actionType == "http",
               let jsonString = action.actionDetailsJSON[actionIdentifier],
               let jsonData = jsonString.data(using: .utf8),
               let details = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let urlString = details["url"] as? String,
               let url = URL(string: urlString) {
                executeHttpAction(url: url, details: details)
            } else if let urlString = action.actionURLs[actionIdentifier],
                      let url = URL(string: urlString) {
                Log.info("Opening URL from ntfy action: \(urlString)")
                openUrlSecurely(url, serverBaseURL: action.serverBaseURL)
            }
            return
        }

        // Handle config-based actions
        guard let serverBaseURL = action.serverBaseURL,
              let topicConfig = topicConfig(serverBaseURL: serverBaseURL, topic: action.topic),
              let actions = topicConfig.actions else {
            return
        }

        let matchingAction = actions.first { configAction in
            let actionId = "action-\(configAction.title.lowercased().replacingOccurrences(of: " ", with: "-"))"
            return actionId == actionIdentifier
        }

        if let configAction = matchingAction {
            if configAction.type == "script", let path = configAction.path {
                Log.info("Executing action script: \(path)")
                scriptRunner?.runScript(
                    at: path,
                    arguments: configAction.args,
                    withArgument: action.messageBody,
                    extraEnv: nil,
                    timeout: Subprocess.defaultTimeout
                )
            } else if configAction.type == "view", let urlString = configAction.url, let url = URL(string: urlString) {
                Log.info("Opening URL from config action: \(urlString)")
                openUrlSecurely(url, serverBaseURL: serverBaseURL)
            } else if configAction.type == "shortcut", let name = configAction.name {
                Log.info("Running shortcut from config action: \(name)")
                scriptRunner?.runShortcut(named: name, withInput: action.messageBody)
            } else if configAction.type == "applescript" {
                if let scriptSource = configAction.script {
                    Log.info("Running inline AppleScript from config action")
                    scriptRunner?.runAppleScript(source: scriptSource)
                } else if let path = configAction.path {
                    Log.info("Running AppleScript file from config action: \(path)")
                    scriptRunner?.runAppleScriptFile(at: path)
                }
            }
        }
    }
}
