import AppKit
import XCTest
@testable import NtfyxCore

@MainActor
final class SettingsCloseGuardTests: XCTestCase {

    private final class DummyDelegate: NSObject, NSWindowDelegate {
        var becameKeyCount = 0
        var closeAskedCount = 0
        var allowClose = true

        func windowDidBecomeKey(_ notification: Notification) {
            becameKeyCount += 1
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            closeAskedCount += 1
            return allowClose
        }
    }

    private func makeSettingsWindow() -> (NSWindow, DummyDelegate) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "ntfyx 设置"
        let dummy = DummyDelegate()
        window.delegate = dummy
        return (window, dummy)
    }

    func testInstallWrapsSwiftUIDelegateExactlyOnce() {
        _ = NSApplication.shared
        let (window, _) = makeSettingsWindow()

        SettingsCloseGuard.install(viewModel: SettingsViewModel())
        let first = window.delegate
        XCTAssertTrue(first is SettingsCloseDelegateProxy, "windowShouldClose must be intercepted by the proxy")

        SettingsCloseGuard.install(viewModel: SettingsViewModel())
        XCTAssertTrue(window.delegate === first, "re-running install must not double-wrap the delegate")
    }

    func testProxyForwardsUnrelatedDelegateCallbacks() {
        _ = NSApplication.shared
        let (window, dummy) = makeSettingsWindow()
        SettingsCloseGuard.install(viewModel: SettingsViewModel())
        let proxy = window.delegate

        XCTAssertTrue(proxy?.responds(to: #selector(NSWindowDelegate.windowDidBecomeKey(_:))) ?? false)
        proxy?.perform(#selector(NSWindowDelegate.windowDidBecomeKey(_:)),
                       with: Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertEqual(dummy.becameKeyCount, 1, "non-close delegate callbacks must reach SwiftUI's original delegate")
    }

    func testCleanCloseDefersToOriginalDelegate() {
        _ = NSApplication.shared
        let (window, dummy) = makeSettingsWindow()
        SettingsCloseGuard.install(viewModel: SettingsViewModel())
        let proxy = try! XCTUnwrap(window.delegate as? SettingsCloseDelegateProxy)

        // Fresh view model: no unsaved changes, so the close decision is SwiftUI's own.
        XCTAssertTrue(proxy.windowShouldClose(window))
        XCTAssertEqual(dummy.closeAskedCount, 1)

        dummy.allowClose = false
        XCTAssertFalse(proxy.windowShouldClose(window))
        XCTAssertEqual(dummy.closeAskedCount, 2)
    }
}
