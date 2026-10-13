import SwiftUI

/// Scene-level root for the SwiftUI Settings scene.
///
/// Owns the settings view model for the scene's lifetime (equivalent to the old
/// persistent settings window), loads config on first appearance, and attaches the
/// unsaved-changes close guard to the scene's NSWindow. Live connection rows and the sync
/// facade are injected by the app's composition root (audit B2 — no copied state).
public struct SettingsRootView: View {
    private let connections: ConnectionRegistry
    private let configStore: ConfigStore
    private let syncService: ConfigSyncService

    @State private var viewModel: SettingsViewModel?
    @State private var didLoad = false

    public init(connections: ConnectionRegistry, configStore: ConfigStore, syncService: ConfigSyncService) {
        self.connections = connections
        self.configStore = configStore
        self.syncService = syncService
    }

    public var body: some View {
        Group {
            if let viewModel {
                SettingsView(viewModel: viewModel, syncService: syncService)
                    .navigationTitle("ntfyx 设置")
            } else {
                ProgressView()
                    .navigationTitle("ntfyx 设置")
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            let viewModel = SettingsViewModel(connections: connections, configStore: configStore)
            viewModel.loadFromConfig()
            self.viewModel = viewModel
            SettingsCloseGuard.install(viewModel: viewModel)
        }
    }
}
