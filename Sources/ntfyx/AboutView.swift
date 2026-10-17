import SwiftUI
import NtfyxCore

/// Contents of the About window scene, replacing the hand-built AppKit panel.
struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ntfyx")
                .font(.system(size: 18, weight: .bold))

            Text(LF("版本 %@", AppConstants.effectiveVersion))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text(bodyText)
                .font(.system(size: 12))
                .padding(.top, 10)

            Spacer(minLength: 0)

            Text(L("基于 MIT 许可证开源"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 380, height: 210)
        .textSelection(.enabled)
        // The scene's own `Window(_:)` title is fixed when the app launches, so this view-level
        // title is what lets 设置 → 界面语言 repaint the title bar immediately.
        .navigationTitle(L("关于 ntfyx"))
    }

    /// Assembled per evaluation so a language switch rewrites the credits without a relaunch.
    private var bodyText: AttributedString {
        let markdown = [
            L("ntfy.sh 的原生 macOS 客户端"),
            "",
            LF("作者：%@", "[Felix2yu](https://github.com/Felix2yu)"),
            "[ntfyx on GitHub](https://github.com/Felix2yu/ntfyx)",
            "",
            LF(
                "致谢：%@（本项目原作者）、%@（ntfy 作者）",
                "[Laurent FRANCOISE](https://laurentftech.github.io)",
                "[Philipp C. Heckel](https://github.com/binwiederhier)"
            ),
        ].joined(separator: "\n")
        return (try? AttributedString(markdown: markdown)) ?? AttributedString("ntfyx")
    }
}
