import Foundation

/// UserDefaults keys for app-level (non-config-file) settings.
public enum AppSettings {
    static let expandMessagesByDefaultKey = "historyExpandMessagesByDefault"
    static let messageFontSizeKey = "historyMessageFontSize"
    static let historySidebarWidthKey = "historySidebarWidth"
    public static let iCloudSyncEnabledKey = "icloudSyncEnabled"
    public static let iCloudSyncDirectoryKey = "icloudSyncDirectory"
}
