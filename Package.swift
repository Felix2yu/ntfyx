// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ntfyx",
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
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .target(
            name: "NtfyxCore",
            dependencies: ["Yams"],
            path: "Sources/NtfyxCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
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
            dependencies: ["NtfyxCore", "Yams"],
            path: "Tests/ntfyxCoreTests",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
