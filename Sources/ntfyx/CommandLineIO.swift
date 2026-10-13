import Foundation
import NtfyxCore

/// Usage text and redirect messages for the app binary's CLI surface.
/// Only `serve` and `test-notify` still live here; one-shot commands moved to ntfyxctl.
enum CommandLineIO {
    static func printRedirected(_ command: String) {
        print("'\(command)' 已移至 ntfyxctl 命令行工具。")
        print("请使用：ntfyxctl \(command) …（详见 ntfyxctl --help）")
    }

    static func printUnknown(_ command: String) {
        print("未知命令：\(command)")
        printUsage()
    }

    static func printUsage() {
        print("""
        ntfyx - 原生 macOS 通知与自动化工具（GUI/常驻服务程序）

        用法：
            ntfyx <命令> [选项]

        命令：
            serve                    启动通知服务
                --config <PATH>      可选：自定义配置文件路径

            test-notify              发送测试通知
                --topic <NAME>       要测试的主题名称

            help                     显示本帮助信息

        纯命令行工具（钥匙串令牌、iCloud 配置同步、生成示例配置）：
            ntfyxctl --help

        示例：
            ntfyx serve
            ntfyx serve --config /path/to/config.yml
            ntfyx test-notify --topic alerts

        配置：
            默认配置位置：~/.config/ntfyx/config.yml

        更多信息请访问：https://github.com/Felix2yu/ntfyx
        """)
    }
}
