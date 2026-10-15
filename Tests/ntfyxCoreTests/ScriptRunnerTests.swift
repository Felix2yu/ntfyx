import XCTest
@testable import NtfyxCore

final class ScriptRunnerTests: XCTestCase {
    var runner: ScriptRunner!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        runner = ScriptRunner()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("script-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        super.tearDown()
    }

    // MARK: - Script Validation

    func testValidateScriptNotFound() {
        let result = runner.validateScript(at: "/nonexistent/path/script.sh")
        XCTAssertFalse(result)
    }

    func testValidateScriptIsDirectory() {
        let result = runner.validateScript(at: tempDir.path)
        XCTAssertFalse(result)
    }

    func testValidateScriptNotExecutable() throws {
        let scriptPath = tempDir.appendingPathComponent("not-executable.sh")
        try "#!/bin/bash\necho hello".write(to: scriptPath, atomically: true, encoding: .utf8)

        // File exists but is not executable
        let result = runner.validateScript(at: scriptPath.path)
        XCTAssertFalse(result)
    }

    func testValidateScriptExecutable() throws {
        let scriptPath = tempDir.appendingPathComponent("executable.sh")
        try "#!/bin/bash\necho hello".write(to: scriptPath, atomically: true, encoding: .utf8)

        // Make it executable
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let result = runner.validateScript(at: scriptPath.path)
        XCTAssertTrue(result)
    }

    // MARK: - Script Execution

    func testRunScriptSynchronouslySimple() throws {
        let scriptPath = tempDir.appendingPathComponent("simple.sh")
        try "#!/bin/bash\necho 'Hello World'".write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let result = runner.runScriptSynchronously(at: scriptPath.path)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("Hello World"))
        XCTAssertTrue(result.error.isEmpty)
    }

    func testRunScriptSynchronouslyWithArgument() throws {
        let scriptPath = tempDir.appendingPathComponent("with-arg.sh")
        try "#!/bin/bash\necho \"Received: $1\"".write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let result = runner.runScriptSynchronously(at: scriptPath.path, withArgument: "test-message")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("Received: test-message"))
    }

    func testRunScriptSynchronouslyExitCode() throws {
        let scriptPath = tempDir.appendingPathComponent("exit-code.sh")
        try "#!/bin/bash\nexit 42".write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let result = runner.runScriptSynchronously(at: scriptPath.path)

        XCTAssertEqual(result.exitCode, 42)
    }

    func testRunScriptSynchronouslyStderr() throws {
        let scriptPath = tempDir.appendingPathComponent("stderr.sh")
        try "#!/bin/bash\necho 'Error message' >&2".write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let result = runner.runScriptSynchronously(at: scriptPath.path)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.error.contains("Error message"))
    }

    func testRunScriptSynchronouslyNotFound() {
        let result = runner.runScriptSynchronously(at: "/nonexistent/script.sh")

        XCTAssertEqual(result.exitCode, -1)
        XCTAssertTrue(result.error.contains("Failed to execute"))
    }

    func testRunScriptWithEnvironmentPath() throws {
        // Test that the enhanced PATH is set
        let scriptPath = tempDir.appendingPathComponent("check-path.sh")
        try "#!/bin/bash\necho $PATH".write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let result = runner.runScriptSynchronously(at: scriptPath.path)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("/opt/homebrew/bin"))
        XCTAssertTrue(result.output.contains("/usr/local/bin"))
    }

    // MARK: - Special Characters

    func testRunScriptWithSpecialCharactersInArgument() throws {
        let scriptPath = tempDir.appendingPathComponent("special-chars.sh")
        try "#!/bin/bash\necho \"Arg: $1\"".write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let specialArg = "Hello 'World' with \"quotes\" and $pecial chars!"
        let result = runner.runScriptSynchronously(at: scriptPath.path, withArgument: specialArg)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("Hello"))
    }

    func testRunScriptWithUnicodeArgument() throws {
        let scriptPath = tempDir.appendingPathComponent("unicode.sh")
        try "#!/bin/bash\necho \"Message: $1\"".write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let unicodeArg = "🔔 Notification: été, naïve, 日本語"
        let result = runner.runScriptSynchronously(at: scriptPath.path, withArgument: unicodeArg)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("🔔"))
    }

    // MARK: - Extra Environment Variables

    func testRunScriptWithExtraEnvVars() throws {
        let scriptPath = tempDir.appendingPathComponent("env-test.sh")
        try """
        #!/bin/bash
        echo "TOPIC:$NTFY_TOPIC"
        echo "TITLE:$NTFY_TITLE"
        echo "PRIORITY:$NTFY_PRIORITY"
        echo "TAGS:$NTFY_TAGS"
        """.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let env: [String: String] = [
            "NTFY_TOPIC": "alerts",
            "NTFY_TITLE": "Test Alert",
            "NTFY_PRIORITY": "4",
            "NTFY_TAGS": "warning,fire",
        ]
        let result = runner.runScriptSynchronously(at: scriptPath.path, extraEnv: env)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("TOPIC:alerts"))
        XCTAssertTrue(result.output.contains("TITLE:Test Alert"))
        XCTAssertTrue(result.output.contains("PRIORITY:4"))
        XCTAssertTrue(result.output.contains("TAGS:warning,fire"))
    }

    func testRunScriptWithExtraEnvAndArgument() throws {
        let scriptPath = tempDir.appendingPathComponent("env-arg-test.sh")
        try """
        #!/bin/bash
        echo "ARG:$1"
        echo "ID:$NTFY_ID"
        echo "MSG:$NTFY_MESSAGE"
        """.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let env: [String: String] = [
            "NTFY_ID": "abc123",
            "NTFY_MESSAGE": "Hello World",
        ]
        let result = runner.runScriptSynchronously(at: scriptPath.path, withArgument: "Hello World", extraEnv: env)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("ARG:Hello World"))
        XCTAssertTrue(result.output.contains("ID:abc123"))
        XCTAssertTrue(result.output.contains("MSG:Hello World"))
    }

    func testRunScriptWithNilExtraEnv() throws {
        let scriptPath = tempDir.appendingPathComponent("nil-env.sh")
        try "#!/bin/bash\necho 'OK'".write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let result = runner.runScriptSynchronously(at: scriptPath.path, extraEnv: nil)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("OK"))
    }

    func testRunScriptExtraEnvDoesNotOverridePATH() throws {
        let scriptPath = tempDir.appendingPathComponent("path-env.sh")
        try "#!/bin/bash\necho $PATH".write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let env: [String: String] = [
            "PATH": "/evil/path",
            "NTFY_TOPIC": "test",
        ]
        let result = runner.runScriptSynchronously(at: scriptPath.path, extraEnv: env)

        XCTAssertEqual(result.exitCode, 0)
        // extraEnv must not be able to clobber the enhanced PATH
        XCTAssertTrue(result.output.contains("/opt/homebrew/bin"))
        XCTAssertFalse(result.output.contains("/evil/path"))
    }

    // MARK: - ShellWord tokenizer

    func testShellWordSplit() {
        XCTAssertEqual(ShellWord.split("foo bar baz"), ["foo", "bar", "baz"])
        XCTAssertEqual(ShellWord.split("foo 'bar baz' qux"), ["foo", "bar baz", "qux"])
        XCTAssertEqual(ShellWord.split(#"foo "bar baz" qux"#), ["foo", "bar baz", "qux"])
        XCTAssertEqual(ShellWord.split(#"foo\ bar"#), ["foo bar"])
        XCTAssertEqual(ShellWord.split("  spaced  out "), ["spaced", "out"])
        XCTAssertEqual(ShellWord.split(""), [])
        XCTAssertNil(ShellWord.split("foo 'bar"))
        XCTAssertNil(ShellWord.split(#"foo "bar"#))
        XCTAssertNil(ShellWord.split("foo\\"))
    }

    func testShellWordJoinRoundTrip() {
        let cases: [[String]] = [
            ["foo", "bar"],
            ["foo", "bar baz"],
            ["a'b", "c\"d"],
            ["$HOME", ";", "a;b", "`id`", "*", ""],
            ["中文", "🔔"],
        ]
        for words in cases {
            let joined = ShellWord.join(words)
            XCTAssertEqual(ShellWord.split(joined), words, "round-trip failed for \(words) → \(joined)")
        }
        XCTAssertEqual(ShellWord.join(["simple", "words"]), "simple words")
        XCTAssertEqual(ShellWord.join(["$HOME"]), "'$HOME'")
    }

    // MARK: - ScriptCommand construction

    func testScriptCommandExplicitArgsBypassShell() {
        let command = ScriptCommand.make(
            spec: "/opt/bin/notify",
            explicitArgs: ["$HOME", ";", "a;b", "`id`"],
            messageArgument: "the body"
        )
        XCTAssertEqual(command?.executable, "/opt/bin/notify")
        XCTAssertFalse(command?.shell ?? true)
        XCTAssertEqual(command?.arguments, ["$HOME", ";", "a;b", "`id`", "the body"])
    }

    func testScriptCommandDirectExecForSafeSpec() {
        let command = ScriptCommand.make(spec: "/usr/bin/printf '%s\\n'", messageArgument: nil)
        XCTAssertEqual(command?.executable, "/usr/bin/printf")
        XCTAssertFalse(command?.shell ?? true)
        XCTAssertEqual(command?.arguments, ["%s\\n"])
    }

    func testScriptCommandFallsBackToShellForMetacharacters() {
        for spec in [
            "/bin/echo a | /usr/bin/cat",
            "/bin/echo a; /bin/echo b",
            "FOO=bar /opt/bin/run",
            "/bin/echo $HOME",
            "/bin/echo *.txt",
        ] {
            let command = ScriptCommand.make(spec: spec, messageArgument: nil)
            XCTAssertEqual(command?.executable, ScriptCommand.shellPath, "expected shell for \(spec)")
            XCTAssertTrue(command?.shell ?? false, "expected shell flag for \(spec)")
            XCTAssertEqual(command?.arguments.first, "-c")
        }
    }

    func testScriptCommandBareNameStaysShell() {
        // Foundation Process does no PATH lookup; legacy `say hello` ran via /bin/sh.
        let command = ScriptCommand.make(spec: "say hello", messageArgument: nil)
        XCTAssertEqual(command?.executable, ScriptCommand.shellPath)
        XCTAssertTrue(command?.shell ?? false)
    }

    func testScriptCommandQuotedPathDirectExec() {
        let command = ScriptCommand.make(spec: "'/tmp/my scripts/run' --flag", messageArgument: nil)
        XCTAssertEqual(command?.executable, "/tmp/my scripts/run")
        XCTAssertFalse(command?.shell ?? true)
        XCTAssertEqual(command?.arguments, ["--flag"])
    }

    // MARK: - Direct exec injection immunity

    func testExplicitArgsArePassedLiterally() throws {
        // argv-dumper: prints one bracketed line per argument.
        let scriptPath = tempDir.appendingPathComponent("argv-dump.sh")
        try """
        #!/bin/bash
        for a in "$@"; do echo "[$a]"; done
        """.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let hostileArgs = ["$HOME", ";", "a; rm -f /tmp/ntfyx-should-not-exist", "`id`", "$(whoami)", "'single'", "\"double\"", "*", "a b"]
        let result = runner.runScriptSynchronously(at: scriptPath.path, arguments: hostileArgs)

        XCTAssertEqual(result.exitCode, 0)
        for arg in hostileArgs {
            XCTAssertTrue(result.output.contains("[\(arg)]"), "missing literal argv line for \(arg) in\n\(result.output)")
        }
        // No shell word splitting: the space-containing arg is one line.
        XCTAssertTrue(result.output.contains("[a b]"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/ntfyx-should-not-exist"))
    }

    func testExplicitArgsMessageAppendedLast() throws {
        let scriptPath = tempDir.appendingPathComponent("argv-count.sh")
        try """
        #!/bin/bash
        echo "count:$# first:$1 last:${!#}"
        """.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        let result = runner.runScriptSynchronously(
            at: scriptPath.path, arguments: ["first"], withArgument: "last-arg"
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("count:2"))
        XCTAssertTrue(result.output.contains("first:first"))
        XCTAssertTrue(result.output.contains("last:last-arg"))
    }

    // MARK: - Shell fallback keeps legacy behaviour

    func testShellModeStillInterpretsPipeline() throws {
        let result = Subprocess.runBlocking(
            executable: ScriptCommand.shellPath,
            arguments: ["-c", "/bin/echo hello | /usr/bin/tr a-z A-Z"],
            environment: Subprocess.environment(extra: nil)
        )
        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("HELLO"))
    }

    // MARK: - Timeout watchdog

    func testTimeoutTerminatesProcess() {
        let start = Date()
        let result = Subprocess.runBlocking(
            executable: "/bin/sleep",
            arguments: ["30"],
            environment: Subprocess.environment(extra: nil),
            timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(result.launched)
        XCTAssertTrue(result.timedOut)
        // A process still alive at the deadline would block waitUntilExit for 30 seconds.
        XCTAssertLessThan(elapsed, 15, "watchdog did not reap the timed-out process")
    }

    func testTimeoutEscalatesToSIGKILL() throws {
        // Ignores SIGTERM on purpose: only the 5-second SIGKILL escalation can reap it.
        let scriptPath = tempDir.appendingPathComponent("ignore-term.sh")
        try """
        #!/bin/bash
        trap '' TERM
        sleep 30
        """.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let start = Date()
        let result = Subprocess.runBlocking(
            executable: scriptPath.path,
            arguments: [],
            environment: Subprocess.environment(extra: nil),
            timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(result.launched)
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.exitCode, 0)
        // SIGTERM alone would leave it running for the remaining ~29 seconds.
        XCTAssertGreaterThan(elapsed, 4)
        XCTAssertLessThan(elapsed, 12)
    }

    func testTimeoutSIGTERMGracefulExit() throws {
        let scriptPath = tempDir.appendingPathComponent("trap-term.sh")
        try """
        #!/bin/bash
        trap 'exit 99' TERM
        sleep 30
        """.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let start = Date()
        let result = Subprocess.runBlocking(
            executable: scriptPath.path,
            arguments: [],
            environment: Subprocess.environment(extra: nil),
            timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, 99)
        XCTAssertLessThan(elapsed, 4, "SIGTERM should have ended the process before the kill grace period")
    }

    func testNoTimeoutWhenProcessFinishes() {
        let result = Subprocess.runBlocking(
            executable: "/bin/sleep",
            arguments: ["0"],
            environment: Subprocess.environment(extra: nil),
            timeout: 5
        )
        XCTAssertTrue(result.launched)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testFailedLaunchReported() {
        let result = Subprocess.runBlocking(
            executable: "/nonexistent/binary-xyz",
            arguments: [],
            environment: Subprocess.environment(extra: nil)
        )
        XCTAssertFalse(result.launched)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, -1)
    }

    // MARK: - Validation

    func testValidateScriptBareNameResolvedOnPATH() {
        XCTAssertTrue(runner.validateScript(at: "echo"))
        XCTAssertTrue(runner.validateScript(at: "echo with args"))
        XCTAssertFalse(runner.validateScript(at: "definitely-not-a-real-command-xyz"))
    }

    func testValidateScriptQuotedFirstToken() throws {
        let scriptURL = tempDir.appendingPathComponent("my script.sh")
        try "#!/bin/bash\necho ok".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        XCTAssertTrue(runner.validateScript(at: "'\(scriptURL.path)' --flag"))
    }
}
