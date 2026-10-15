import Foundation
import NtfyxCore

/// Pure one-shot command-line tool: keychain tokens, iCloud config sync and sample
/// config creation. It never initializes AppKit or a run loop (audit A1).
@main
struct CLITool {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments

        guard arguments.count >= 2 else {
            printUsage()
            exit(1)
        }

        let command = arguments[1]
        switch command {
        case "auth":
            handleAuth(arguments: arguments)
        case "sync":
            handleSync(arguments: arguments)
        case "init":
            handleInit(arguments: arguments)
        case "help", "--help", "-h":
            printUsage()
            exit(0)
        default:
            print("未知命令：\(command)")
            printUsage()
            exit(1)
        }
    }

    // MARK: - auth

    @MainActor
    static func handleAuth(arguments: [String]) {
        // Check for subcommand: add, list, remove
        guard arguments.count >= 3 else {
            printAuthUsage()
            exit(1)
        }

        let subcommand = arguments[2]

        switch subcommand {
        case "add":
            // ntfyxctl auth add <server-url> <token>
            guard arguments.count >= 5 else {
                print("用法：ntfyxctl auth add <server-url> <token>")
                exit(1)
            }
            let server = arguments[3]
            let token = arguments[4]

            do {
                try KeychainHelper.saveToken(token, forServer: server)
                print("✅ 已为服务器保存令牌：\(server)")
            } catch {
                print("❌ 保存令牌失败：\(error)")
                exit(1)
            }

        case "list":
            do {
                let servers = try KeychainHelper.listServers()
                if servers.isEmpty {
                    print("钥匙串中未存储任何令牌。")
                } else {
                    print("已为以下服务器存储令牌：")
                    for server in servers {
                        print("  • \(server)")
                    }
                }
            } catch {
                print("❌ 列出服务器失败：\(error)")
                exit(1)
            }

        case "remove":
            guard arguments.count >= 4 else {
                print("用法：ntfyxctl auth remove <server-url>")
                exit(1)
            }
            let server = arguments[3]

            do {
                try KeychainHelper.deleteToken(forServer: server)
                print("✅ 已删除服务器的令牌：\(server)")
            } catch {
                print("❌ 删除令牌失败：\(error)")
                exit(1)
            }

        default:
            print("未知的 auth 子命令：\(subcommand)")
            printAuthUsage()
            exit(1)
        }
    }

    // MARK: - sync

    @MainActor
    static func handleSync(arguments: [String]) {
        guard arguments.count >= 3 else {
            printSyncUsage()
            exit(1)
        }
        let subcommand = arguments[2]

        let enabled = UserDefaults.standard.bool(forKey: AppSettings.iCloudSyncEnabledKey)
        let storedDirectory = UserDefaults.standard.string(forKey: AppSettings.iCloudSyncDirectoryKey) ?? ""
        // --dir applies to this run only: a one-off sync from a script or a second account
        // must not quietly repoint the app's own sync folder.
        let cliDirectory = getFlag(arguments: arguments, flag: "--dir")
        let isCustom = !(cliDirectory ?? storedDirectory).isEmpty
        let store = CloudConfigStore(directoryOverride: cliDirectory ?? (storedDirectory.isEmpty ? nil : storedDirectory))

        switch subcommand {
        case "status":
            printSyncStatus(store: store, enabled: enabled, isCustom: isCustom)

        case "pull", "push":
            guard enabled || cliDirectory != nil else {
                print("❌ iCloud 同步未开启。先在 ntfyx 设置 → iCloud 同步 中打开，或用 --dir <PATH> 指定同步文件夹。")
                exit(1)
            }

            let local: AppConfig
            do {
                // The CLI is a stateless one-shot: read the default file directly, no
                // shared in-memory store involved (audit E3).
                local = try ConfigFile.read(from: ConfigStore.defaultConfigPath).config
            } catch {
                print("❌ 读取本地配置失败：\(error)")
                print("   默认配置位置：\(ConfigStore.defaultConfigPath)，可先运行 'ntfyxctl init' 创建。")
                exit(1)
            }

            let preferCloud = subcommand == "pull"
            print(preferCloud ? "🔄 正在拉取云端配置（冲突以云端为准）…" : "🔄 正在推送本机配置（冲突以本机为准）…")

            var state = SyncStateStore.load()
            do {
                let outcome = try ConfigSyncEngine.run(
                    local: local,
                    base: state.base ?? .empty,
                    resolution: preferCloud ? .preferCloud : .preferLocal,
                    store: store
                )
                state.base = outcome.merged
                state.lastSyncedAt = Date()
                SyncStateStore.save(state)

                print("✅ 同步完成：\(outcome.servers) 个服务器、\(outcome.topics) 个主题")
                print(outcome.wroteLocal
                    ? "   本机配置已更新：\(ConfigStore.defaultConfigPath)"
                    : "   本机配置无需改动")
                print(outcome.wroteCloud
                    ? "   云端文件已写入：\(store.cloudFileURL.path)"
                    : "   云端文件无需改动")
                if outcome.conflictCopiesMerged > 0 {
                    print("   已合并并清理 \(outcome.conflictCopiesMerged) 个 iCloud 冲突副本")
                }
                print("   上传与下载由系统在后台完成，其他设备稍后才看得到。")
                if outcome.wroteLocal {
                    print("   ntfyx 正在运行的话会自动热重载这份配置。")
                }
            } catch {
                print("❌ 同步失败：\(error.localizedDescription)")
                if let syncError = error as? ConfigSyncError, case .cloudNotDownloaded = syncError {
                    print("   已向 iCloud 请求下载云端副本，稍后重试即可。")
                }
                exit(1)
            }

        default:
            print("未知的 sync 子命令：\(subcommand)")
            printSyncUsage()
            exit(1)
        }
    }

    static func printSyncStatus(store: CloudConfigStore, enabled: Bool, isCustom: Bool) {
        print("iCloud 同步：\(enabled ? "已开启" : "未开启")")
        print("同步文件夹：\(store.rootDirectory)\(isCustom ? "（自定义）" : "")")

        let cloudPath = store.cloudFileURL.path
        if FileManager.default.fileExists(atPath: cloudPath) {
            let size = ((try? FileManager.default.attributesOfItem(atPath: cloudPath))?[.size] as? Int) ?? 0
            print("云端文件：已存在（\(size) 字节）")
        } else {
            print("云端文件：尚不存在（首次同步时创建）")
        }

        let state = SyncStateStore.load()
        if let base = state.base {
            print("本机基线：\(base.servers.count) 个服务器、\(base.topicCount) 个主题")
        } else {
            print("本机基线：尚无（这台机器还没完成过同步）")
        }
        if let date = state.lastSyncedAt {
            print("上次同步：\(SyncTimeFormat.string(date))")
        } else {
            print("上次同步：从未")
        }

        let conflicts = store.conflictCopies().count
        if conflicts > 0 {
            print("冲突副本：\(conflicts) 个，下次同步会合并进来")
        }
        if !enabled {
            print("")
            print("未开启时 pull/push 需要 --dir <PATH> 指定同步文件夹；持续同步由设置中的开关控制。")
        }
    }

    // MARK: - init

    @MainActor
    static func handleInit(arguments: [String]) {
        let configPath = getFlag(arguments: arguments, flag: "--path") ?? ConfigStore.defaultConfigPath

        do {
            if try ConfigFile.createSampleConfig(at: configPath) {
                print("示例配置已创建于：\(configPath)")
                print("请编辑配置文件，然后运行 'ntfyx serve' 启动服务。")
            } else {
                print("配置文件已存在，未做修改：\(configPath)")
            }
        } catch {
            print("创建配置失败：\(error)")
            exit(1)
        }
    }

    // MARK: - Helpers / usage

    static func getFlag(arguments: [String], flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    static func printSyncUsage() {
        print("""
        用法：ntfyxctl sync <子命令> [--dir <PATH>]

        子命令：
            status          显示同步状态（只读）
            pull            取云端配置合并到本机，冲突以云端为准
            push            把本机配置合入云端，冲突以本机为准

        pull 与 push 都会把合并结果同时写回本机文件和云端文件，区别只在冲突时以哪边
        为准；服务器与主题的新增取并集，任一边删除都生效。

        --dir 只作用于本次运行，不会改动设置里的同步文件夹。

        示例：
            ntfyxctl sync status
            ntfyxctl sync pull
            ntfyxctl sync push --dir /Volumes/nas/ntfyx

        注意：命令行只做一次合并。配置改动自动上云、定时拉取这些持续同步，
        仍由运行中的 ntfyx 服务负责。
        """)
    }

    static func printAuthUsage() {
        print("""
        用法：ntfyxctl auth <子命令>

        子命令：
            add <server-url> <token>    将令牌存入钥匙串
            list                        列出所有已存令牌的服务器
            remove <server-url>         从钥匙串删除令牌

        示例：
            ntfyxctl auth add https://ntfy.sh tk_mytoken
            ntfyxctl auth list
            ntfyxctl auth remove https://ntfy.sh
        """)
    }

    static func printUsage() {
        print("""
        ntfyxctl - ntfyx 的纯命令行工具

        用法：
            ntfyxctl <命令> [选项]

        命令：
            auth <子命令>            管理钥匙串中的认证令牌
                add <url> <token>    为服务器存储令牌
                list                 列出所有已存令牌的服务器
                remove <url>         删除某服务器的令牌

            sync <子命令>            iCloud 配置同步（--dir <PATH> 可临时指定同步文件夹）
                status               显示同步状态（只读）
                pull                 取云端配置合并到本机，冲突以云端为准
                push                 把本机配置合入云端，冲突以本机为准

            init                     创建示例配置文件
                --path <PATH>        可选：自定义配置文件路径

            help                     显示本帮助信息

        示例：
            ntfyxctl init
            ntfyxctl auth add https://ntfy.sh tk_yourtoken
            ntfyxctl sync pull

        常驻通知服务请使用 ntfyx（GUI 应用）：ntfyx serve

        更多信息请访问：https://github.com/Felix2yu/ntfyx
        """)
    }
}
