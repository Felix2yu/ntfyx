// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ntfyx",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v27)
    ],
    products: [
        .executable(
            name: "ntfyx",
            targets: ["ntfyx"]
        ),
        .executable(
            name: "ntfyxctl",
            targets: ["ntfyxctl"]
        ),
        .library(
            name: "NtfyxCore",
            targets: ["NtfyxCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0")
    ],
    targets: [
        .target(
            name: "NtfyxCore",
            dependencies: [
                "Yams",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/NtfyxCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "ntfyx",
            dependencies: ["NtfyxCore"],
            path: "Sources/ntfyx",
            swiftSettings: [
                // Swift 6.2 默认 MainActor 隔离：app 入口与菜单栏 UI 都在主线程。
                .defaultIsolation(MainActor.self)
            ]
        ),
        .executableTarget(
            name: "ntfyxctl",
            dependencies: ["NtfyxCore"],
            path: "Sources/ntfyxctl"
        ),
        .testTarget(
            name: "ntfyxCoreTests",
            dependencies: [
                "NtfyxCore",
                "Yams",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Tests/ntfyxCoreTests"
        )
    ]
)
