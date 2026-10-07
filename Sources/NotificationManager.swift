import Foundation
import CryptoKit
@preconcurrency import UserNotifications
import AppKit

final class NotificationManager: NSObject, @unchecked Sendable {
    static let shared = NotificationManager()

    private lazy var center: UNUserNotificationCenter = {
        dispatchPrecondition(condition: .onQueue(.main))
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    private let lock = NSLock()
    private var _scriptRunner: (any ScriptRunnerProtocol)?

    /// Icons and action categories describe a topic, not a message, but both used to be
    /// rebuilt for every banner: the SF Symbol round trip (TIFF → PNG) per message, and a
    /// `getNotificationCategories` + `setNotificationCategories` pair — two XPC calls plus a copy
    /// of the whole registered set — per message too. Memoizing by shape means the render happens
    /// once per distinct symbol and the registration once per distinct action set.
    private let memoLock = NSLock()
    private var _iconPNG: [String: Data] = [:]
    private var _iconRenderFailures: Set<String> = []
    private var _iconsDirectoryReady = false
    private var _registeredCategoryKeys: Set<String> = []

    private let throttle = NotificationThrottle()

    /// Single banner that replaces the flood while a message storm is in progress.
    static let burstSummaryIdentifier = "ntfy:burst-summary"

    /// How ntfy's message priority decides banner delivery, mirroring the mobile
    /// clients: 1 (min) never interrupts, 2 (low) arrives quietly.
    enum PriorityHandling: Equatable {
        case suppressed   // priority <= 1: history only, no banner at all
        case passive      // priority == 2: banner without sound, outside the burst throttle
        case normal
    }

    static func priorityHandling(for priority: Int?) -> PriorityHandling {
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
        memoLock.lock()
        _registeredCategoryKeys.removeAll()
        memoLock.unlock()
        Log.info("Cleared notification categories")
    }

    /// Sets the script runner - accepts protocol for DI/testing
    func setScriptRunner(_ runner: any ScriptRunnerProtocol) {
        lock.lock()
        defer { lock.unlock() }
        self._scriptRunner = runner
    }

    private var scriptRunner: (any ScriptRunnerProtocol)? {
        lock.lock()
        defer { lock.unlock() }
        return _scriptRunner
    }

    /// Requests notification permissions from the user
    func requestAuthorization(completion: @escaping @Sendable (Bool, Error?) -> Void) {
        // Check current authorization status first
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                // Permission not requested yet - request directly without blocking alert
                print("📱 Requesting notification permissions...")
                print("   A system dialog will appear - please click 'Allow'")

                DispatchQueue.main.async {
                    NSApplication.shared.activate(ignoringOtherApps: true)

                    // Request authorization directly - this will show the system dialog
                    self.center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                        if granted {
                            print("✅ Notification permission granted!")
                        } else {
                            print("")
                            print("⚠️  Notification permission was denied or the dialog didn't appear")
                            print("")
                            print("💡 The app is now registered in System Settings.")
                            print("   To enable notifications manually:")
                            print("   1. Open System Settings → Notifications")
                            print("   2. Scroll down and find 'ntfyx'")
                            print("   3. Toggle on 'Allow Notifications'")
                            print("")
                            print("   Then restart ntfyx")
                        }
                        completion(granted, error)
                    }
                }
            } else if settings.authorizationStatus == .authorized {
                print("✅ Notification permissions already granted")
                completion(true, nil)
            } else {
                print("")
                print("⚠️  Notification permissions are currently denied or restricted")
                print("")
                print("💡 To enable notifications:")
                print("   1. Open System Settings → Notifications")
                print("   2. Scroll down and find 'ntfyx' in the list")
                print("   3. Toggle on 'Allow Notifications'")
                print("")
                print("   Then restart ntfyx")
                completion(false, nil)
            }
        }
    }

    func getAuthorizationStatus(completion: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { settings in
            completion(settings.authorizationStatus)
        }
    }

    // MARK: - Banner identity

    /// Delivered notifications are keyed by the ntfy message id rather than a random UUID,
    /// so a message read or deleted on *any* device can be traced back to its banner.
    static func identifier(forMessageID messageID: String) -> String {
        "ntfy:\(messageID)"
    }

    /// User Notifications aborts the process (`bundleProxyForCurrentProcess is nil`) unless
    /// the executable runs out of an app bundle, which is also the only case where there can
    /// be banners to talk about.
    static var canManageBanners: Bool {
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
        DispatchQueue.main.async {
            self.center.removeDeliveredNotifications(withIdentifiers: identifiers)
            self.center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
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
            print("Silent notification for topic \(message.topic) - skipping display")
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
            showBurstSummary(count: count, topics: topics, firstOfBurst: firstOfBurst, absorbed: absorbed)
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
        content.title = "\(count) 条新消息"
        let shownTopics = topics.prefix(3).joined(separator: "、")
        if topics.count > 3 {
            content.body = "消息过于集中，已合并显示：\(shownTopics) 等 \(topics.count) 个主题"
        } else {
            content.body = "消息过于集中，已合并显示：\(shownTopics)"
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
    static let catchUpSummaryIdentifier = "ntfy:catch-up-summary"

    func showCatchUpSummary(count: Int, topics: [String]) {
        guard count > 0, Self.canManageBanners else { return }

        let content = UNMutableNotificationContent()
        content.title = "补齐 \(count) 条消息"
        let shownTopics = topics.prefix(3).joined(separator: "、")
        if topics.count > 3 {
            content.body = "已收录历史：\(shownTopics) 等 \(topics.count) 个主题"
        } else {
            content.body = "已收录历史：\(shownTopics)"
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

    private func showTopicNotification(for message: NtfyMessage, topicConfig: TopicConfig, serverURL: String?, passive: Bool = false) {
        let content = UNMutableNotificationContent()
        let emojiPrefix = EmojiTags.emojiPrefix(for: message.tags)
        // Use plain text versions to strip markdown syntax (macOS notifications don't render markdown)
        content.title = emojiPrefix + (message.plainTextTitle ?? message.title ?? "\(message.topic)")
        content.body = message.plainTextMessage ?? message.message ?? "\(message.topic)"
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
        content.body = message.plainTextMessage ?? message.message ?? ""
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
                print("Failed to show notification: \(error)")
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
        memoLock.lock()
        defer { memoLock.unlock() }

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

    private static func pngData(for image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func iconFileName(for symbolName: String) -> String {
        let safeName = symbolName.map {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_"
        }
        return String(safeName) + ".png"
    }

    private static let iconCacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("ntfyx/icons", isDirectory: true)
    }()

    /// Identifier shared by every message whose notification buttons look the same. The
    /// buttons resolve their URLs and types from each notification's own userInfo, so the
    /// category only has to describe the labels — keying it by message id registered one new
    /// category per message and never removed any, so the set Notification Center holds grew
    /// without bound.
    static func messageActionCategoryID(_ actions: [NtfyMessage.NtfyAction]) -> String {
        let shape = actions.prefix(4).map { "\($0.action):\($0.label)" }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(shape.utf8))
        return "msg-actions-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Registers a category unless this identifier + action set has already been registered:
    /// the get/set pair is two XPC calls plus a copy of the entire registered set, and every
    /// banner of a topic asks for exactly the same one.
    private func registerCategory(identifier: String, actions: [UNNotificationAction]) {
        let key = identifier + "|" + actions.map { "\($0.identifier)=\($0.title)" }.joined(separator: ",")
        memoLock.lock()
        let seen = _registeredCategoryKeys.contains(key)
        if !seen { _registeredCategoryKeys.insert(key) }
        memoLock.unlock()
        guard !seen else { return }

        let category = UNNotificationCategory(
            identifier: identifier,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )

        center.getNotificationCategories { existingCategories in
            // Remove any existing category with the same ID before inserting
            // (Set.insert won't replace, so we must remove first)
            var categories = existingCategories.filter { $0.identifier != identifier }
            categories.insert(category)
            self.center.setNotificationCategories(categories)
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

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                Log.error("HTTP action failed: \(error.localizedDescription)")
            } else if let httpResponse = response as? HTTPURLResponse {
                Log.info("HTTP action completed with status: \(httpResponse.statusCode)")
            }
        }.resume()
    }

    /// Opens a URL securely by validating its scheme and domain against the allowed values in server config
    /// - Parameters:
    ///   - url: The URL to open
    ///   - serverBaseURL: base URL of the server that delivered the message — the same topic
    ///     name can exist on several servers, so the allow-list must come from the right one
    private func openUrlSecurely(_ url: URL, serverBaseURL: String?) {
        let serverConfig = serverBaseURL.flatMap { ConfigManager.shared.config?.server(forURL: $0) }

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
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    func showTestNotification(topic: String) {
        let content = UNMutableNotificationContent()
        content.title = "测试通知"
        content.body = "主题 \(topic) 的测试通知"
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
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // No `.badge` here: the Dock badge is the unread count from the history store, and
        // letting Notification Center increment it too would show a number nobody recognises.
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let messageBody = userInfo["messageBody"] as? String ?? ""
        let topic = userInfo["topic"] as? String ?? ""

        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            // User clicked on the notification itself - open web view
            openNotificationInWeb(userInfo: userInfo)
        } else if response.actionIdentifier != UNNotificationDismissActionIdentifier {
            handleActionResponse(response, messageBody: messageBody, topic: topic)
        }

        completionHandler()
    }

    private func openNotificationInWeb(userInfo: [AnyHashable: Any]) {
        guard let serverUrl = userInfo["serverUrl"] as? String, !serverUrl.isEmpty,
              let topic = userInfo["topic"] as? String else {
            return
        }

        let isCustomClickUrl = userInfo["isCustomClickUrl"] as? Bool ?? false
        let serverBaseURL = userInfo["serverBaseURL"] as? String

        // If custom URL, use it directly; otherwise append topic to server URL
        let webUrlString = isCustomClickUrl ? serverUrl : "\(serverUrl)/\(topic)"
        if let url = URL(string: webUrlString) {
            openUrlSecurely(url, serverBaseURL: serverBaseURL)
        }
    }

    private func handleActionResponse(_ response: UNNotificationResponse, messageBody: String, topic: String) {
        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let serverBaseURL = userInfo["serverBaseURL"] as? String

        // Check for ntfy message actions
        if actionIdentifier.hasPrefix("ntfy-action-") {
            let actionTypes = userInfo["actionTypes"] as? [String: String] ?? [:]
            let actionType = actionTypes[actionIdentifier] ?? "view"

            if actionType == "http",
               let actionDetailsJson = userInfo["actionDetailsJson"] as? [String: String],
               let jsonString = actionDetailsJson[actionIdentifier],
               let jsonData = jsonString.data(using: .utf8),
               let details = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let urlString = details["url"] as? String,
               let url = URL(string: urlString) {
                executeHttpAction(url: url, details: details)
            } else if let actionUrls = userInfo["actionUrls"] as? [String: String],
                      let urlString = actionUrls[actionIdentifier],
                      let url = URL(string: urlString) {
                Log.info("Opening URL from ntfy action: \(urlString)")
                openUrlSecurely(url, serverBaseURL: serverBaseURL)
            }
            return
        }

        // Handle config-based actions
        guard let serverBaseURL,
              let topicConfig = ConfigManager.shared.topicConfig(serverURL: serverBaseURL, topic: topic),
              let actions = topicConfig.actions else {
            return
        }

        let matchingAction = actions.first { action in
            let actionId = "action-\(action.title.lowercased().replacingOccurrences(of: " ", with: "-"))"
            return actionId == actionIdentifier
        }

        if let action = matchingAction {
            if action.type == "script", let path = action.path {
                Log.info("Executing action script: \(path)")
                scriptRunner?.runScript(at: path, withArgument: messageBody, extraEnv: nil)
            } else if action.type == "view", let urlString = action.url, let url = URL(string: urlString) {
                Log.info("Opening URL from config action: \(urlString)")
                openUrlSecurely(url, serverBaseURL: serverBaseURL)
            } else if action.type == "shortcut", let name = action.name {
                Log.info("Running shortcut from config action: \(name)")
                scriptRunner?.runShortcut(named: name, withInput: messageBody)
            } else if action.type == "applescript" {
                if let scriptSource = action.script {
                    Log.info("Running inline AppleScript from config action")
                    scriptRunner?.runAppleScript(source: scriptSource)
                } else if let path = action.path {
                    Log.info("Running AppleScript file from config action: \(path)")
                    scriptRunner?.runAppleScriptFile(at: path)
                }
            }
        }
    }
}
