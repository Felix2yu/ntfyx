// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ntfyx",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v26)
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
            path: "Sources/ntfyx"
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
