import AppKit
import Observation

/// Per-server connectivity, plus the menu-bar-only signals derived from it.
///
/// The single source of truth for connection state (audit B2): the running coordinator
/// writes states here, and the menu bar / settings screen observe the same instance
/// through the injected `AppEnvironment`. The 0.6 s connecting pulse is the only pure-UI
/// timer left in the app (audit F3 keeps it).
@MainActor
@Observable
public final class ConnectionRegistry {
    public static let shared = ConnectionRegistry()

    public enum ConnectionState {
        case connecting    // Never connected yet (orange, flashing)
        case connected     // Currently connected (green)
        case disconnected  // Was connected, now lost (red)
    }

    /// One subscribed topic as the menu shows it: the id never changes, the label is the
    /// user's 备注 when they set one.
    public struct TopicRow: Equatable, Sendable {
        public let id: String
        public let label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }

        /// Hover text naming the English id, but only where it adds information to the label.
        public var idTooltip: String { label == id ? "" : L10n.format("主题 id：%@", id) }
    }

    public struct ServerConnectionStatus {
        public let url: String
        public let topics: [TopicRow]
        public var isConnected: Bool
        public var hasEverConnected: Bool  // Track if we've ever successfully connected
        public var hasFailedAttempt: Bool  // Track if at least one attempt ended in failure

        public init(url: String,
                    topics: [TopicRow],
                    isConnected: Bool,
                    hasEverConnected: Bool,
                    hasFailedAttempt: Bool = false) {
            self.url = url
            self.topics = topics
            self.isConnected = isConnected
            self.hasEverConnected = hasEverConnected
            self.hasFailedAttempt = hasFailedAttempt
        }

        public var state: ConnectionState {
            if isConnected {
                return .connected
            } else if hasEverConnected || hasFailedAttempt {
                return .disconnected
            } else {
                return .connecting
            }
        }
    }

    /// What the config row of the menu bar shows.
    public enum ConfigIssue: Equatable {
        case warning(String)
        case error(String)
    }

    /// The single status row at the top of the menu bar menu.
    public struct StatusLine {
        public enum Dot: Equatable {
            case none
            case green
            case red
            /// Orange dot whose visibility toggles with the connecting pulse.
            case orangePulse
        }

        public let dot: Dot
        public let text: String
    }

    public private(set) var statuses: [String: ServerConnectionStatus] = [:]
    public var configIssue: ConfigIssue?
    public var unreadCount = 0

    /// Toggles every 0.6s while at least one server is still connecting; views render the
    /// orange dot only while this is true.
    public private(set) var pulseVisible = true

    /// Observation ignores the pulse plumbing; it only drives the dot animation.
    @ObservationIgnored private var pulseTimer: Timer?

    public init() {}

    // MARK: - Server list / state

    /// Applies a new server list while keeping the connection state of servers that
    /// stayed subscribed — used by the incremental config reload (audit 2.2), where
    /// untouched connections must not blink back to "connecting".
    public func updateServers(servers: [(url: String, topics: [TopicRow])]) {
        stopPulse()
        var updated: [String: ServerConnectionStatus] = [:]
        for server in servers {
            if let existing = statuses[server.url] {
                updated[server.url] = ServerConnectionStatus(
                    url: existing.url, topics: server.topics,
                    isConnected: existing.isConnected,
                    hasEverConnected: existing.hasEverConnected,
                    hasFailedAttempt: existing.hasFailedAttempt
                )
            } else {
                updated[server.url] = ServerConnectionStatus(
                    url: server.url, topics: server.topics,
                    isConnected: false, hasEverConnected: false
                )
            }
        }
        statuses = updated
        startPulseIfNeeded()
    }

    public func setServerConnected(_ serverUrl: String, connected: Bool) {
        guard var status = statuses[serverUrl] else { return }
        status.isConnected = connected
        if connected {
            status.hasEverConnected = true
        } else {
            status.hasFailedAttempt = true
        }
        statuses[serverUrl] = status
        if hasConnectingServers { startPulseIfNeeded() } else { stopPulse() }
    }

    public func setUnreadCount(_ count: Int) {
        guard count != unreadCount else { return }
        unreadCount = count
    }

    // MARK: - Config issue row

    public func showConfigWarning(_ warning: String) {
        configIssue = .warning(warning)
    }

    public func showConfigError(_ error: String) {
        configIssue = .error(error)
    }

    public func clearConfigIssue() {
        configIssue = nil
    }

    // MARK: - Derived menu row

    public var hasDisconnectedServers: Bool {
        statuses.values.contains { $0.state == .disconnected }
    }

    public var statusLine: StatusLine {
        let totalServers = statuses.count
        let connectedServers = statuses.values.filter { $0.state == .connected }.count
        let connectingServers = statuses.values.filter { $0.state == .connecting }.count
        let disconnectedServers = statuses.values.filter { $0.state == .disconnected }.count
        let totalTopics = statuses.values.flatMap { $0.topics }.count

        if totalServers == 0 {
            return StatusLine(dot: .none, text: L("未配置服务器"))
        } else if connectedServers == totalServers {
            return StatusLine(dot: .green, text: LF("%1$d 台服务器 · %2$d 个主题", totalServers, totalTopics))
        } else if connectingServers > 0 && disconnectedServers == 0 && connectedServers == 0 {
            return StatusLine(dot: .orangePulse, text: L("连接中…"))
        } else if disconnectedServers > 0 {
            return StatusLine(dot: .red, text: LF("已连接 %1$d/%2$d 台服务器", connectedServers, totalServers))
        } else {
            // Mixed state: some connected, some connecting.
            return StatusLine(dot: .orangePulse, text: LF("已连接 %1$d/%2$d 台服务器", connectedServers, totalServers))
        }
    }

    /// Sorted snapshot for stable menu rendering.
    public var sortedStatuses: [ServerConnectionStatus] {
        statuses.values.sorted { $0.url < $1.url }
    }

    // MARK: - Connecting pulse

    private var hasConnectingServers: Bool {
        statuses.values.contains { $0.state == .connecting }
    }

    private func startPulseIfNeeded() {
        guard hasConnectingServers, pulseTimer == nil else { return }
        pulseVisible = true
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pulseVisible.toggle()
            }
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseVisible = true
    }
}
