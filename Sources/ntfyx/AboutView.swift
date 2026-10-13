import SwiftUI
import NtfyxCore

/// Contents of the About window scene, replacing the hand-built AppKit panel.
struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ntfyx")
                .font(.system(size: 18, weight: .bold))

            Text("版本 \(AppConstants.effectiveVersion)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text(AboutView.bodyText)
                .font(.system(size: 12))
                .padding(.top, 10)

            Spacer(minLength: 0)

            Text("基于 MIT 许可证开源")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 340, height: 200)
        .textSelection(.enabled)
    }

    private static let bodyText: AttributedString = {
        let markdown = """
        ntfy.sh 的原生 macOS 客户端

        作者：[Laurent FRANCOISE](https://laurentftech.github.io)
        [ntfyx on GitHub](https://github.com/Felix2yu/ntfyx)

        基于 [ntfy](https://ntfy.sh) 构建，作者 Philipp C. Heckel
        """
        return (try? AttributedString(markdown: markdown)) ?? AttributedString("ntfyx")
    }()
}
