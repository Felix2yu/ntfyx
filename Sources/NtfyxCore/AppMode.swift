import AppKit

/// How the binary was launched.
public enum LaunchMode: Equatable {
    /// Double-click / `open`: no arguments. Dock icon, regular activation policy.
    case dock
    /// `serve [--config PATH]`: menu-bar-only background service.
    case serve(configPath: String?)
    /// `test-notify --topic NAME`: request permission, deliver one notification, exit.
    case testNotify(topic: String?)
    case help
    /// `auth` / `sync` / `init` now live in the ntfyxctl binary; associated value is the
    /// subcommand name used in the redirect message.
    case redirected(String)
    case unknown(String)
}

/// Distinguishes the ways this binary can run and applies the activation policy.
public enum AppMode {
    // Written once at launch on the main actor (configure(arguments:)), before any reader.
    @MainActor
    public private(set) static var isDockApp = false

    @MainActor
    public private(set) static var mode: LaunchMode = .dock

    /// The only argument of a bare launch is the executable path itself.
    public static func isDockLaunch(arguments: [String]) -> Bool {
        arguments.count < 2
    }

    /// Parses the command line into a launch mode (pure logic; no AppKit side effects).
    public static func parse(_ arguments: [String]) -> LaunchMode {
        guard !isDockLaunch(arguments: arguments) else { return .dock }

        let command = arguments[1]
        switch command {
        case "serve":
            return .serve(configPath: flagValue(arguments: arguments, flag: "--config"))
        case "test-notify":
            return .testNotify(topic: flagValue(arguments: arguments, flag: "--topic"))
        case "help", "--help", "-h":
            return .help
        case "auth", "sync", "init":
            return .redirected(command)
        default:
            return .unknown(command)
        }
    }

    private static func flagValue(arguments: [String], flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    @MainActor
    public static func configure(arguments: [String] = CommandLine.arguments) {
        let parsed = parse(arguments)
        mode = parsed
        isDockApp = parsed == .dock
        NSApp.setActivationPolicy(isDockApp ? .regular : .accessory)
    }

    /// A background service has no Dock icon to keep it alive, so closing its last window
    /// must demote the app to menu-bar-only. A Dock app keeps running.
    @MainActor
    public static func demoteToAccessoryIfNeeded() {
        guard !isDockApp else { return }
        _ = NSApp.setActivationPolicy(.accessory)
    }
}
