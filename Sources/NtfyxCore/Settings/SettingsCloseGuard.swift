import AppKit

/// Gives the SwiftUI Settings scene window the old "unsaved changes?" close prompt
/// without hijacking its delegate: installs a forwarding proxy that intercepts only
/// `windowShouldClose(_:)` and relays every other callback to SwiftUI's own delegate.
@MainActor
enum SettingsCloseGuard {
    private static var associationKey: UInt8 = 0

    static func install(viewModel: SettingsViewModel) {
        if let window = settingsWindow {
            attachIfNeeded(window: window, viewModel: viewModel)
            return
        }
        // The scene's window can land one run-loop tick after onAppear.
        DispatchQueue.main.async {
            guard let window = settingsWindow else { return }
            attachIfNeeded(window: window, viewModel: viewModel)
        }
    }

    private static var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.title == L("ntfyx 设置") }
    }

    private static func attachIfNeeded(window: NSWindow, viewModel: SettingsViewModel) {
        guard !(window.delegate is SettingsCloseDelegateProxy) else { return }
        let proxy = SettingsCloseDelegateProxy(
            original: window.delegate as? NSObject,
            viewModel: viewModel
        )
        // NSWindow.delegate is weak; bind the proxy's lifetime to the window itself.
        objc_setAssociatedObject(window, &associationKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        window.delegate = proxy
    }
}

/// Forwards everything to SwiftUI's window delegate except the close decision,
/// which runs the three-way unsaved-changes alert.
@MainActor
final class SettingsCloseDelegateProxy: NSObject, NSWindowDelegate {
    // NSObject's responds(to:)/forwardingTarget(for:) overrides are nonisolated entry
    // points; AppKit always invokes them on the main thread.
    nonisolated(unsafe) private weak var original: NSObject?
    private let viewModel: SettingsViewModel

    init(original: NSObject?, viewModel: SettingsViewModel) {
        self.original = original
        self.viewModel = viewModel
        super.init()
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(NSWindowDelegate.windowShouldClose(_:)) {
            return true
        }
        return original?.responds(to: aSelector) ?? false
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        guard aSelector != #selector(NSWindowDelegate.windowShouldClose(_:)) else {
            return nil
        }
        return original
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let originalDecision: () -> Bool = { [self] in
            ((original as? NSWindowDelegate)?.windowShouldClose?(sender)) ?? true
        }

        guard viewModel.hasUnsavedChanges else { return originalDecision() }

        let alert = NSAlert()
        alert.messageText = L("有未保存的更改")
        alert.informativeText = L("关闭窗口将丢失未保存的配置更改。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("保存并关闭"))
        alert.addButton(withTitle: L("不保存关闭"))
        alert.addButton(withTitle: L("取消"))
        NSApp.activate()

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            viewModel.save()
            if let error = viewModel.saveError {
                let errAlert = NSAlert()
                errAlert.messageText = L("保存失败")
                errAlert.informativeText = error
                errAlert.alertStyle = .critical
                errAlert.addButton(withTitle: L("好"))
                errAlert.runModal()
                return false
            }
            return originalDecision()
        case .alertSecondButtonReturn:
            return originalDecision()
        default:
            return false
        }
    }
}
