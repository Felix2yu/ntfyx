import AppKit
import NtfyxCore

/// Menu/command actions that are not tied to a SwiftUI scene.
@MainActor
enum AppActions {
    static func showConfigInFinder() {
        let configPath = NSString(string: "~/.config/ntfyx").expandingTildeInPath
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: configPath)
    }

    static func viewLogs() {
        // All logs go to the same location with rotation.
        if FileManager.default.fileExists(atPath: Log.logFilePath) {
            NSWorkspace.shared.selectFile(Log.logFilePath, inFileViewerRootedAtPath: Log.logDirectory)
            return
        }

        let alert = NSAlert()
        alert.messageText = "未找到日志"
        alert.informativeText = "尚未生成日志文件。日志将写入 \(Log.logDirectory)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
        // The alert itself is a window; a background service must demote once it closes.
        AppMode.demoteToAccessoryIfNeeded()
    }
}
