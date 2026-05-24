import Foundation

/// Abstraction over Process so tests can inject scripted ssh invocations.
public protocol SSHProcessRunner: Sendable {
    /// Run `ssh` with the given arguments, optional alternate config
    /// file via `-F`, and an injected PATH (rubber-duck B2). Returns
    /// (exitCode, stdout, stderr).
    func runSSH(arguments: [String], configFile: URL?, environment: [String: String]) async throws -> SSHRunResult
}

public struct SSHRunResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Default impl that shells out to `/usr/bin/ssh` (Apple's fork).
/// Per consensus + rubber-duck B2, the path is hard-coded; users running
/// Homebrew OpenSSH on PATH won't be unintentionally picked up.
public struct SystemSSHProcessRunner: SSHProcessRunner {
    public init() {}
    public func runSSH(
        arguments: [String],
        configFile: URL?,
        environment: [String: String]
    ) async throws -> SSHRunResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args: [String] = []
        if let configFile {
            args.append(contentsOf: ["-F", configFile.path])
        }
        args.append(contentsOf: arguments)
        proc.arguments = args
        proc.environment = environment

        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe; proc.standardError = errPipe
        try proc.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return SSHRunResult(
            exitCode: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

/// Effective per-host config as resolved by `ssh -G`. Bastion uses this
/// instead of parsing the user's config tree directly — `ssh -G` is the
/// same code path OpenSSH runs at connect time, so it cannot drift.
public struct EffectiveConfig: Sendable, Equatable {
    /// Lower-cased key → list of values. Single-valued options have a
    /// list of length 1.
    public let values: [String: [String]]

    public init(values: [String: [String]] = [:]) { self.values = values }

    public func first(_ key: String) -> String? {
        values[key.lowercased()]?.first
    }
    public func all(_ key: String) -> [String] {
        values[key.lowercased()] ?? []
    }

    /// Per rubber-duck B5: normalise `controlpath`'s edge values. If the
    /// effective ControlPath is `none`, empty, or missing, the host has
    /// no master path and we must not enqueue `-O check` polling for it.
    public var usableControlPath: String? {
        guard let raw = first("controlpath") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.caseInsensitiveCompare("none") == .orderedSame { return nil }
        return trimmed
    }

    /// True iff `ControlMaster` is set to anything other than `no` or
    /// missing. Combined with `usableControlPath` to decide whether to
    /// poll the master.
    public var controlMasterEnabled: Bool {
        guard let raw = first("controlmaster") else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed == "yes" || trimmed == "auto" || trimmed == "ask" || trimmed == "autoask"
    }
}

/// Wraps `ssh -G alias` to produce an `EffectiveConfig`. Multi-valued
/// keys are gathered into arrays per `SSHOption.isMultiValued`. Single
/// values overwrite — `ssh -G` emits the resolved value, so the "first
/// match wins" precedence is already baked in.
public struct SSHGReader {
    public let runner: SSHProcessRunner
    public let environment: [String: String]

    public init(runner: SSHProcessRunner = SystemSSHProcessRunner(), environment: [String: String] = [:]) {
        self.runner = runner
        self.environment = environment
    }

    public func effectiveConfig(forAlias alias: String, configFile: URL? = nil) async throws -> EffectiveConfig {
        let result = try await runner.runSSH(
            arguments: ["-G", alias],
            configFile: configFile,
            environment: environment
        )
        if result.exitCode != 0 {
            throw SSHConfigError.validationFailed(stderr: result.stderr)
        }
        return Self.parse(stdout: result.stdout)
    }

    /// Like `effectiveConfig` but with a hard wall-clock timeout that
    /// actually kills the spawned `ssh -G` process. Needed because
    /// `CanonicalizeHostname yes` + `Match exec` directives can cause
    /// `ssh -G` to do DNS lookups and run shell commands — turning a
    /// nominal 5-20ms config parse into a multi-second hang on flaky
    /// VPN / slow DNS. Rubber-duck pass: pre-flight in the connect path
    /// can't tolerate that, so the editor and connect callers route
    /// through this variant.
    ///
    /// Returns nil on timeout (caller treats as "couldn't probe" and
    /// falls back to best-effort behaviour). Throws on actual ssh -G
    /// errors (e.g. malformed alias).
    public func effectiveConfigWithTimeout(
        forAlias alias: String,
        timeout: TimeInterval = 0.5
    ) async -> EffectiveConfig? {
        var args = ["-G"]
        args.append(alias)
        let result = await ProcessTimeout.run(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: args,
            environment: environment.isEmpty ? nil : environment,
            timeout: timeout
        )
        if result.timedOut { return nil }
        guard let exit = result.exitCode, exit == 0 else { return nil }
        return Self.parse(stdout: result.stdout)
    }

    /// Parse the `key value\n` lines `ssh -G` emits. The parser is
    /// strictly line-oriented (rubber-duck S2): values may legitimately
    /// contain spaces (paths like `/Users/Some User/.ssh/id_ed25519`).
    public static func parse(stdout: String) -> EffectiveConfig {
        var values: [String: [String]] = [:]
        let multi: Set<String> = Set(SSHOption.allCases.filter { $0.isMultiValued }.map { $0.rawValue })

        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            // Split into key + value at first run of whitespace.
            guard let space = rawLine.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                let key = String(rawLine).lowercased()
                values[key, default: []].append("")
                continue
            }
            let key = String(rawLine[..<space]).lowercased()
            let value = String(rawLine[rawLine.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            if multi.contains(key) {
                values[key, default: []].append(value)
            } else {
                values[key] = [value]
            }
        }
        return EffectiveConfig(values: values)
    }
}
