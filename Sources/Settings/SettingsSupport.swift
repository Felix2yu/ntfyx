import SwiftUI

// MARK: - Token Management Sheet

struct TokenSheetView: View {
    @Binding var server: EditableServer
    @Environment(\.dismiss) private var dismiss

    @State private var tokenText: String = ""
    @State private var storageChoice: TokenStorage = .keychain

    enum TokenStorage: String, CaseIterable {
        case keychain = "钥匙串（推荐）"
        case configFile = "配置文件"
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if !server.token.isEmpty {
                        HStack {
                            Label(
                                server.storeInKeychain ? "当前存于钥匙串" : "当前存于配置文件",
                                systemImage: server.storeInKeychain ? "key.fill" : "doc.text"
                            )
                            Spacer()
                            Button {
                                server.token = ""
                                server.storeInKeychain = false
                                dismiss()
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("删除令牌")
                        }
                    }
                } header: {
                    Text("当前状态")
                }

                Section {
                    SecureField("输入令牌", text: $tokenText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("令牌")

                    Picker("存储位置", selection: $storageChoice) {
                        ForEach(TokenStorage.allCases, id: \.self) { storage in
                            Text(storage.rawValue).tag(storage)
                        }
                    }
                } header: {
                    Text(server.token.isEmpty ? "添加令牌" : "替换令牌")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("保存令牌") {
                    server.token = tokenText
                    server.storeInKeychain = (storageChoice == .keychain)
                    dismiss()
                }
                .disabled(tokenText.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(12)
        }
        .frame(width: 420, height: 280)
        .onAppear {
            storageChoice = server.storeInKeychain ? .keychain : .configFile
        }
    }
}

// MARK: - Click-URL security options (audit 3.3)

/// Tri-state editing model for the server-level `allowed_schemes` / `allowed_domains`
/// options: absent (default behaviour), an explicit list, or deny-all (empty list).
enum URLRestriction: Hashable {
    case off
    case custom
    case denyAll

    init(deriving list: [String]?) {
        guard let list else { self = .off; return }
        self = list.isEmpty ? .denyAll : .custom
    }
}

/// Comma/semicolon/space separated input → lowercased list, empty entries dropped.
func parseRestrictionList(_ text: String) -> [String] {
    text.lowercased()
        .components(separatedBy: CharacterSet(charactersIn: ",; "))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}
