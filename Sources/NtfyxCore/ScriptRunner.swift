import Foundation

// MARK: - Structured subprocess invocation

/// One argv-level subprocess description. The default path is a direct `execve`
/// with literal arguments; `shell == true` is used only when the command string
/// actually needs shell interpretation (pipes, globs, expansions…).
struct ScriptCommand: Sendable, Equatable {
    var executable: String
    var arguments: [String]
    var shell: Bool

    static let shellPath = "/bin/sh"

    /// Builds an invocation from a config string.
    ///
    /// - Parameters:
    ///   - spec: Executable path, optionally followed by arguments. Either a bare
    ///     path (`/usr/bin/foo --bar`) or a POSIX-quoted string (`'/path with x'`).
    ///   - explicitArgs: Structured arguments from config (`auto_run_script_args` /
    ///     action `args`). When present, the spec is treated as a path only and the
    ///     command never goes through a shell.
    ///   - messageArgument: Notification body, appended as one literal argv element
    ///     (direct mode) or single-quote escaped (shell mode).
    static func make(
        spec raw: String?,
        explicitArgs: [String]? = nil,
        messageArgument: String? = nil
    ) -> ScriptCommand? {
        guard let spec = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !spec.isEmpty else {
            return nil
        }

        if let explicitArgs {
            var arguments = explicitArgs
            if let messageArgument, !messageArgument.isEmpty {
                arguments.append(messageArgument)
            }
            return ScriptCommand(executable: spec, arguments: arguments, shell: false)
        }

        let tokens = ShellWord.split(spec) ?? []
        // Foundation's `Process` never does PATH lookup, so a bare command name
        // (`say hello`) must stay in shell mode to preserve legacy behaviour.
        if tokens.isEmpty || !tokens[0].contains("/") || Self.needsShell(spec) {
            return ScriptCommand(
                executable: shellPath,
                arguments: ["-c", Self.shellCommandString(spec, message: messageArgument)],
                shell: true
            )
        }

        var arguments = Array(tokens.dropFirst())
        if let messageArgument, !messageArgument.isEmpty {
            arguments.append(messageArgument)
        }
        return ScriptCommand(executable: tokens[0], arguments: arguments, shell: false)
    }

    /// Old `/bin/sh -c` semantics: appends the message with safe single-quote escaping.
    private static func shellCommandString(_ spec: String, message: String?) -> String {
        guard let message, !message.isEmpty else { return spec }
        let escaped = message.replacingOccurrences(of: "'", with: "'\\''")
        return "\(spec) '\(escaped)'"
    }

    /// Characters that only make sense under shell interpretation. Detection errs
    /// towards shell mode so legacy strings keep their exact old behaviour.
    private static let shellMetacharacters = CharacterSet(
        charactersIn: "|&;<>()$`*?[]{}!#~"
    ).union(.newlines).union(.controlCharacters)

    private static func needsShell(_ spec: String) -> Bool {
        if spec.rangeOfCharacter(from: shellMetacharacters) != nil { return true }
        // Leading `VAR=value command` (temporary environment assignment).
        if spec.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*=\S*\s"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        return false
    }
}

/// POSIX-ish shell word tokenizer: single/double quoting and backslash escapes,
/// without invoking a shell. Returns nil on an unmatched quote or trailing
/// backslash so the caller can fall back to real shell parsing.
enum ShellWord {
    static func split(_ input: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var hasContent = false

        func flush() {
            if hasContent {
                words.append(current)
                current = ""
                hasContent = false
            }
        }

        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            switch c {
            case " ", "\t", "\n":
                flush()
                i = input.index(after: i)

            case "'":
                hasContent = true
                i = input.index(after: i)
                var closed = false
                while i < input.endIndex {
                    if input[i] == "'" {
                        closed = true
                        i = input.index(after: i)
                        break
                    }
                    current.append(input[i])
                    i = input.index(after: i)
                }
                if !closed { return nil }

            case "\"":
                hasContent = true
                i = input.index(after: i)
                var closed = false
                while i < input.endIndex {
                    let ch = input[i]
                    if ch == "\"" {
                        closed = true
                        i = input.index(after: i)
                        break
                    }
                    if ch == "\\" {
                        let after = input.index(after: i)
                        if after < input.endIndex,
                           ["\"", "\\", "$", "`"].contains(input[after]) {
                            current.append(input[after])
                            i = input.index(after: after)
                            continue
                        }
                        current.append("\\")
                        i = after
                        continue
                    }
                    current.append(ch)
                    i = input.index(after: i)
                }
                if !closed { return nil }

            case "\\":
                hasContent = true
                let after = input.index(after: i)
                guard after < input.endIndex else { return nil }
                current.append(input[after])
                i = input.index(after: after)

            default:
                hasContent = true
                current.append(c)
                i = input.index(after: i)
            }
        }
        flush()
        return words
    }

    /// Inverse of `split` for round-tripping an argv array through one text field:
    /// quotes a word only when it would otherwise be reshaped by a shell.
    static func join(_ words: [String]) -> String {
        words.map { word in
            if word.isEmpty
                || word.rangeOfCharacter(from: .whitespaces) != nil
                || word.contains(where: { "\"'\\|&;<>()$`*?[]{}!#~".contains($0) }) {
                return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            return word
        }
        .joined(separator: " ")
    }
}

// MARK: - Unified subprocess runner

struct ProcessResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    /// False when the executable could not even be launched (missing file, not executable…).
    var launched: Bool
}

/// One `Process` wrapper used by every external-command path (scripts, Shortcuts,
/// AppleScript). Captures both streams without blocking, enforces a timeout with
/// SIGTERM → SIGKILL escalation, and normalises PATH.
enum Subprocess {
    static let defaultTimeout: TimeInterval = 120
    static let killGracePeriod: TimeInterval = 5
    static let enhancedPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func environment(extra: [String: String]?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // Set first; caller extraEnv must not be able to clobber PATH.
        environment["PATH"] = enhancedPATH
        if let extra {
            for (key, value) in extra {
                if key == "PATH" { continue }
                environment[key] = value
            }
        }
        return environment
    }

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval = defaultTimeout
    ) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    timeout: timeout
                ))
            }
        }
    }

    static func runBlocking(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval = defaultTimeout
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let stdoutBox = OutputBox()
        let stderrBox = OutputBox()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let eofGroup = DispatchGroup()
        eofGroup.enter()
        eofGroup.enter()
        installReader(on: stdoutPipe.fileHandleForReading, into: stdoutBox, group: eofGroup)
        installReader(on: stderrPipe.fileHandleForReading, into: stderrBox, group: eofGroup)

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return ProcessResult(
                exitCode: -1,
                stdout: "",
                stderr: "Failed to execute: \(error.localizedDescription)",
                timedOut: false,
                launched: false
            )
        }

        let watchdog = Watchdog(process: process, timeout: timeout)
        watchdog.start()
        process.waitUntilExit()
        watchdog.cancel()

        // Drain trailing output: EOF callbacks are delivered on a background queue.
        _ = eofGroup.wait(timeout: .now() + 2)

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdoutBox.string,
            stderr: stderrBox.string,
            timedOut: watchdog.didTimeOut,
            launched: true
        )
    }

    private static func installReader(
        on handle: FileHandle,
        into box: OutputBox,
        group: DispatchGroup
    ) {
        handle.readabilityHandler = { readHandle in
            let data = readHandle.availableData
            if data.isEmpty {
                readHandle.readabilityHandler = nil
                group.leave()
            } else {
                box.append(data)
            }
        }
    }

    /// Lock-protected output accumulator (readabilityHandler fires on a private queue).
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var string: String {
            lock.lock()
            let copy = data
            lock.unlock()
            return String(decoding: copy, as: UTF8.self)
        }
    }

    /// SIGTERM at the deadline, SIGKILL after a grace period if the process survives.
    private final class Watchdog: @unchecked Sendable {
        private unowned let process: Process
        private let queue = DispatchQueue(label: "ntfyx.subprocess.watchdog")
        private let timeout: TimeInterval
        private var armed = true
        private let timedOutLock = NSLock()
        private var timedOut = false

        init(process: Process, timeout: TimeInterval) {
            self.process = process
            self.timeout = timeout
        }

        func start() {
            guard timeout.isFinite, timeout > 0 else { return }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.fire()
            }
        }

        private func fire() {
            guard armed else { return }

            if process.isRunning {
                timedOutLock.lock()
                timedOut = true
                timedOutLock.unlock()
                process.terminate()
                queue.asyncAfter(deadline: .now() + killGracePeriod) { [weak self] in
                    guard let self, self.armed, self.process.isRunning else { return }
                    kill(self.process.processIdentifier, SIGKILL)
                }
            }
        }

        func cancel() {
            // Same queue as `fire`: a cancel enqueued before the deadline work item
            // is therefore guaranteed to run first.
            queue.async { self.armed = false }
        }

        var didTimeOut: Bool {
            timedOutLock.lock()
            let value = timedOut
            timedOutLock.unlock()
            return value
        }
    }
}

// MARK: - ScriptRunner facade

/// Protocol for script execution - enables dependency injection and mocking for tests
protocol ScriptRunnerProtocol: Sendable {
    /// Runs a script asynchronously with the message body appended as one argument
    func runScript(
        at path: String,
        arguments: [String]?,
        withArgument argument: String?,
        extraEnv: [String: String]?,
        timeout: TimeInterval
    )

    /// Validates that a script exists and is executable
    func validateScript(at path: String) -> Bool

    /// Runs a macOS Shortcut asynchronously
    func runShortcut(named shortcutName: String, withInput input: String?)

    /// Runs an AppleScript from an inline script string
    func runAppleScript(source: String)

    /// Runs an AppleScript from a file path
    func runAppleScriptFile(at path: String)
}

extension ScriptRunnerProtocol {
    func runScript(at path: String, withArgument argument: String? = nil, extraEnv: [String: String]? = nil) {
        runScript(at: path, arguments: nil, withArgument: argument, extraEnv: extraEnv, timeout: Subprocess.defaultTimeout)
    }
}

/// Stateless apart from constants; every method is a fire-and-forget subprocess
/// spawn, so checked `Sendable` conformance needs no locks or isolation.
final class ScriptRunner: ScriptRunnerProtocol, Sendable {

    // MARK: - Scripts

    func runScript(
        at path: String,
        arguments: [String]? = nil,
        withArgument argument: String? = nil,
        extraEnv: [String: String]? = nil,
        timeout: TimeInterval = Subprocess.defaultTimeout
    ) {
        guard let command = ScriptCommand.make(
            spec: path, explicitArgs: arguments, messageArgument: argument
        ) else {
            Log.error("Script path is empty")
            return
        }

        Log.info("Executing script: \(path)")
        if let argument, !argument.isEmpty {
            Log.info("With argument: \(argument)")
        }

        let env = Subprocess.environment(extra: extraEnv)
        Task.detached(priority: .utility) {
            let result = await Subprocess.run(
                executable: command.executable,
                arguments: command.arguments,
                environment: env,
                timeout: timeout
            )
            Self.logFinished(kind: "Script", result: result, timeout: timeout)
        }
    }

    /// Validates that a script exists and is executable
    func validateScript(at path: String) -> Bool {
        guard let scriptPath = Self.firstToken(path) else {
            Log.error("Script path is empty")
            return false
        }
        let fileManager = FileManager.default

        // A bare command name relies on shell PATH lookup at run time; resolve it
        // the same way here instead of rejecting it as a missing relative path.
        let resolvedPath: String
        if scriptPath.contains("/") {
            resolvedPath = scriptPath
        } else if let found = Self.lookupOnPATH(scriptPath) {
            resolvedPath = found
        } else {
            Log.error("Script not found on PATH: \(scriptPath)")
            return false
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            Log.error("Script not found or is a directory: \(resolvedPath)")
            return false
        }

        guard fileManager.isExecutableFile(atPath: resolvedPath) else {
            Log.error("Script is not executable: \(resolvedPath)")
            return false
        }

        return true
    }

    /// The actual file to validate: first word of the spec (quoting-aware).
    private static func firstToken(_ pathWithArgs: String) -> String? {
        guard !pathWithArgs.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let tokens = ShellWord.split(pathWithArgs), let first = tokens.first {
            return first
        }
        // Unmatched quotes / odd input: fall back to the old whitespace split.
        return String(pathWithArgs.split(separator: " ", maxSplits: 1)[0])
    }

    /// Resolves a bare command name against the same PATH the subprocess will see.
    private static func lookupOnPATH(_ name: String) -> String? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? Subprocess.enhancedPATH
        let dirs = Subprocess.enhancedPATH.split(separator: ":").map(String.init)
            + pathEnv.split(separator: ":").map(String.init)
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Shortcuts

    func runShortcut(named shortcutName: String, withInput input: String? = nil) {
        var args = ["run", shortcutName]
        if let input, !input.isEmpty {
            args.append(contentsOf: ["-i", input])
        }

        Log.info("Running shortcut: \(shortcutName)")
        Task.detached(priority: .utility) {
            let result = await Subprocess.run(
                executable: "/usr/bin/shortcuts",
                arguments: args,
                environment: Subprocess.environment(extra: nil)
            )
            if !result.launched {
                Log.error("Failed to run shortcut '\(shortcutName)': \(result.stderr)")
            } else if result.timedOut {
                Log.error("Shortcut '\(shortcutName)' timed out")
            } else if result.exitCode == 0 {
                Log.success("Shortcut '\(shortcutName)' completed successfully")
            } else {
                Log.error("Shortcut '\(shortcutName)' exited with code \(result.exitCode): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    // MARK: - AppleScript

    func runAppleScript(source: String) {
        Log.info("Running AppleScript (inline)")
        Task.detached(priority: .utility) {
            let result = await Subprocess.run(
                executable: "/usr/bin/osascript",
                arguments: ["-e", source],
                environment: Subprocess.environment(extra: nil)
            )
            Self.logFinished(kind: "AppleScript", result: result, timeout: Subprocess.defaultTimeout)
        }
    }

    func runAppleScriptFile(at path: String) {
        Log.info("Running AppleScript file: \(path)")
        Task.detached(priority: .utility) {
            let result = await Subprocess.run(
                executable: "/usr/bin/osascript",
                arguments: [path],
                environment: Subprocess.environment(extra: nil)
            )
            Self.logFinished(kind: "AppleScript file", result: result, timeout: Subprocess.defaultTimeout)
        }
    }

    // MARK: - Shared result logging

    private static func logFinished(kind: String, result: ProcessResult, timeout: TimeInterval) {
        if !result.launched {
            Log.error("\(kind) failed to launch: \(result.stderr)")
            return
        }
        if result.timedOut {
            Log.error("\(kind) timed out after \(Int(timeout))s and was terminated")
            return
        }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode == 0 {
            if !stdout.isEmpty { Log.info("\(kind) output: \(stdout)") }
            Log.success("\(kind) completed successfully")
        } else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.error("\(kind) exited with code \(result.exitCode): \(stderr)")
        }
    }

    // MARK: - Synchronous entry point (tests)

    /// Runs a script synchronously and returns the output.
    func runScriptSynchronously(
        at path: String,
        arguments: [String]? = nil,
        withArgument argument: String? = nil,
        extraEnv: [String: String]? = nil,
        timeout: TimeInterval = Subprocess.defaultTimeout
    ) -> (exitCode: Int32, output: String, error: String) {
        guard let command = ScriptCommand.make(
            spec: path, explicitArgs: arguments, messageArgument: argument
        ) else {
            return (-1, "", "Failed to execute: Script path is empty")
        }
        let result = Subprocess.runBlocking(
            executable: command.executable,
            arguments: command.arguments,
            environment: Subprocess.environment(extra: extraEnv),
            timeout: timeout
        )
        return (result.exitCode, result.stdout, result.stderr)
    }
}
