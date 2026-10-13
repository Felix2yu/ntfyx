import XCTest
@testable import NtfyxCore

final class AppModeTests: XCTestCase {

    private let exe = "/Applications/ntfyx.app/Contents/MacOS/ntfyx"

    func testBareLaunchParsesAsDock() {
        // Double-click / `open`: the executable path is the only argument.
        XCTAssertEqual(AppMode.parse([exe]), .dock)
    }

    func testServeParsesWithNoConfigPath() {
        XCTAssertEqual(AppMode.parse([exe, "serve"]), .serve(configPath: nil))
    }

    func testServeParsesConfigFlag() {
        XCTAssertEqual(
            AppMode.parse([exe, "serve", "--config", "/tmp/c.yml"]),
            .serve(configPath: "/tmp/c.yml")
        )
    }

    func testTestNotifyParsesTopic() {
        XCTAssertEqual(
            AppMode.parse([exe, "test-notify", "--topic", "alerts"]),
            .testNotify(topic: "alerts")
        )
    }

    func testTestNotifyWithoutTopicKeepsNil() {
        // The app layer turns a nil topic into the usage message + exit code 1.
        XCTAssertEqual(AppMode.parse([exe, "test-notify"]), .testNotify(topic: nil))
    }

    func testHelpVariants() {
        XCTAssertEqual(AppMode.parse([exe, "help"]), .help)
        XCTAssertEqual(AppMode.parse([exe, "--help"]), .help)
        XCTAssertEqual(AppMode.parse([exe, "-h"]), .help)
    }

    func testMigratedCommandsParseAsRedirected() {
        for subcommand in ["auth", "sync", "init"] {
            XCTAssertEqual(AppMode.parse([exe, subcommand]), .redirected(subcommand), subcommand)
        }
    }

    func testUnknownCommand() {
        XCTAssertEqual(AppMode.parse([exe, "frobnicate"]), .unknown("frobnicate"))
    }
}
