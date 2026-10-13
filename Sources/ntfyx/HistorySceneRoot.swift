import SwiftUI
import NtfyxCore

/// Root content of the `history` WindowGroup scene: observes the environment's shared
/// history view model, which the scene task prepares once the history store has opened.
struct HistorySceneRoot: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if let viewModel = env.historyVM {
                HistoryView(viewModel: viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle("通知历史")
        .task {
            await env.prepareHistoryViewModel()
        }
    }
}
