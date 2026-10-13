import SwiftUI
import UserNotifications
import NtfyxCore

/// The notification-authorization prompt, presented by the `Window` scene with
/// id `"permission"`. All state transitions live in `PermissionPromptState`;
/// this view only renders the phase and performs the side effects it asks for.
struct PermissionPromptView: View {
    private let state = PermissionPromptCoordinator.shared.state
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 20) {
            Text(message)
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let title = buttonTitle {
                Button(title) { buttonTapped() }
                    .controlSize(.large)
                    .disabled(state.phase == .requesting)
            }
        }
        .frame(width: 500, height: 250)
        .padding(30)
        .task {
            PermissionPromptCoordinator.shared.sceneReady()
        }
        .onChange(of: state.phase) { _, phase in
            guard case .finished = phase else { return }
            // Resolve first; the dismiss triggers onDisappear, which must be a no-op.
            PermissionPromptCoordinator.shared.resolveFromFinishedPhase()
            dismissWindow(id: "permission")
        }
        .onDisappear {
            PermissionPromptCoordinator.shared.resolveFromWindowClose()
        }
    }

    private var message: String {
        switch state.phase {
        case .checking:
            return "正在检查通知权限…"
        case .readyToRequest:
            return "ntfyx 需要权限才能发送通知。\n\n点击下方按钮以请求权限。"
        case .requesting:
            return "正在请求权限…"
        case .denied:
            return "通知权限未授予。\n\n请前往 系统设置 → 通知 → ntfyx 手动开启。"
        case .finished(let granted):
            return granted ? "权限已授予，通知功能已开启。" : "通知权限未授予。"
        }
    }

    private var buttonTitle: String? {
        switch state.phase {
        case .readyToRequest, .requesting:
            return "请求权限"
        case .denied:
            return "打开系统设置"
        case .checking, .finished:
            return nil
        }
    }

    private func buttonTapped() {
        switch state.phase {
        case .readyToRequest:
            state.send(.requestTapped)
            Task { @MainActor in
                do {
                    let granted = try await PermissionService.shared.request()
                    state.send(.requestCompleted(granted: granted))
                } catch {
                    Log.error("Permission error: \(error.localizedDescription)")
                    state.send(.requestFailed)
                }
            }
        case .denied:
            PermissionService.shared.openSystemSettings()
        case .checking, .requesting, .finished:
            break
        }
    }
}
