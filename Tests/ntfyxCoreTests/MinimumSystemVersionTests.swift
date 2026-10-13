import XCTest

/// A built app promises two different system floors: Package.swift decides which APIs the
/// binary may call, Info.plist decides which machines will let it launch. If the second is
/// lower, the app opens on an old system and crashes in an unavailable API rather than
/// refusing to start.
final class MinimumSystemVersionTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/ntfyxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
    }

    private func text(_ relativePath: String) -> String {
        try! String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func platformMajorVersion(from packageSwift: String) -> Int? {
        guard let match = packageSwift.range(of: #"macOS\(\.v(\d+)"#, options: .regularExpression)
        else { return nil }
        return Int(packageSwift[match].filter(\.isNumber))
    }

    private func minimumSystemVersion() -> String? {
        let url = repositoryRoot.appendingPathComponent("Resources/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["LSMinimumSystemVersion"] as? String
    }

    func testInfoPlistMatchesTheCompiledPlatformFloor() {
        let declared = platformMajorVersion(from: text("Package.swift"))
        let advertised = minimumSystemVersion()

        XCTAssertNotNil(declared, "Package.swift should declare a macOS platform")
        XCTAssertNotNil(advertised, "Resources/Info.plist should declare LSMinimumSystemVersion")
        XCTAssertEqual(advertised, declared.map { "\($0).0" })
    }
}
