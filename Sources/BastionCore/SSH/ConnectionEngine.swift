import Foundation

/// Mockable interface for running ssh commands so the engine + tests can
/// inject scripted responses. SystemSSHRunner is the production impl.
public protocol SSHRunner: Sendable {
    /// `ssh` itself: arguments, optional alternate config file via `-F`,
    /// and an environment with our injected PATH.
    func ssh(arguments: [String], environment: [String: String]) async throws -> SSHRunResult
}

public struct SystemSSHRunner: SSHRunner {
    public init() {}
    public func ssh(arguments: [String], environment: [String: String]) async throws -> SSHRunResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = arguments
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

/// Errors the engine raises through the CLI / UI.
public enum EngineError: Error, CustomStringConvertible, Equatable {
    case unknownAlias(String)
    case sshFailed(stderr: String, exit: Int32)
    case validationFailed(reason: String)
    case io(String)

    public var description: String {
        switch self {
        case .unknownAlias(let a):     return "unknown host alias: \(a)"
        case .sshFailed(let s, let e): return "ssh exited \(e): \(s)"
        case .validationFailed(let r): return r
        case .io(let s):               return "I/O: \(s)"
        }
    }
}

/// Stateful, single-process orchestration of every SSH operation Bastion
/// performs. The menu app and CLI both go through this — no Process call
/// to ssh lives anywhere else in the codebase.
///
/// Held as a single instance per process; not @MainActor because it does
/// real work off the main thread, but its methods are async and safe to
/// call from main.
public final class ConnectionEngine: @unchecked Sendable {

    public let store: HostRegistryStore
    public let managedWriter: ManagedConfigWriter
    public let scanner: UserSSHConfigScanner
    public let reader: SSHGReader
    public let sshRunner: SSHRunner
    public let pathResolver: PathResolver
    public let agentProbe: SSHAgentProbe
    public let channelProbe: ChannelCountProbe

    /// In-memory cache of when we first observed each host's master
    /// socket alive. Persisted as part of `status-cache.json` so master
    /// uptime survives menu-app restarts.
    private let masterUptimeStore = MasterUptimeStore()

    public init(
        store: HostRegistryStore = HostRegistryStore(),
        managedWriter: ManagedConfigWriter = ManagedConfigWriter(),
        scanner: UserSSHConfigScanner = UserSSHConfigScanner(),
        reader: SSHGReader = SSHGReader(),
        sshRunner: SSHRunner = SystemSSHRunner(),
        pathResolver: PathResolver = PathResolver(),
        agentProbe: SSHAgentProbe = SSHAgentProbe()
    ) {
        self.store = store
        self.managedWriter = managedWriter
        self.scanner = scanner
        self.reader = reader
        self.sshRunner = sshRunner
        self.pathResolver = pathResolver
        self.agentProbe = agentProbe
        self.channelProbe = ChannelCountProbe(pathResolver: pathResolver)
    }

    // MARK: - Registry operations

    public func loadRegistry() throws -> HostRegistry {
        try store.load()
    }

    /// Upsert a host, rewrite the managed config, isolation+integration
    /// validate. Throws on validation failure; the registry is rolled
    /// back to its pre-upsert state on integration failure.
    public func upsertHost(_ host: ManagedHost, skipIntegrationPass: Bool = false) async throws -> ManagedConfigWriteResult {
        // Model-layer validation — runs before any disk write, so both
        // editor and CLI mutations hit the same FIDO/ControlMaster
        // interlock + socket-path-length sanity check. The editor's
        // async `ssh -G` probe handles the `.inherit` case at the UI
        // level; this is the load-bearing CLI-parity guardrail.
        try host.validateForSave()
        var registry = try store.load()
        let previous = registry
        registry.upsert(host)
        do {
            try store.save(registry)
        } catch {
            // Roll back to previous registry to avoid divergence with
            // bastion.conf which we haven't rewritten yet.
            _ = try? store.save(previous)
            throw error
        }
        do {
            return try await managedWriter.write(registry, skipIntegrationPass: skipIntegrationPass)
        } catch {
            // Restore the previous registry too, so the on-disk state is
            // consistent with the file on disk.
            _ = try? store.save(previous)
            try? managedWriter.rollback()
            throw error
        }
    }

    public func removeHost(_ alias: String) async throws {
        var registry = try store.load()
        guard let host = registry.host(named: alias) else {
            throw EngineError.unknownAlias(alias)
        }
        // Best-effort: try to close a live master so we don't leak the
        // orphan socket. Never let a failing master probe block the
        // delete itself — the user wants the host gone, not a
        // network round-trip diagnostic.
        if let state = try? await checkMaster(alias), state.status == .running {
            _ = try? await stopMaster(alias)
        }
        registry.remove(host.id)
        try store.save(registry)
        _ = try await managedWriter.write(registry, skipIntegrationPass: true)
    }

    // MARK: - ControlMaster lifecycle

    /// `ssh -O check <alias>`. Resolves usable ControlPath via `ssh -G`
    /// first to handle the `controlpath none` case (rubber-duck B5).
    public func checkMaster(_ alias: String) async throws -> ControlMasterState {
        let env = pathResolver.environment()
        let effective: EffectiveConfig
        do {
            effective = try await reader.effectiveConfig(forAlias: alias)
        } catch {
            return ControlMasterState(
                enabled: false,
                status: .unknown,
                lastCheckedAt: Date()
            )
        }
        guard effective.controlMasterEnabled, let socketPath = effective.usableControlPath else {
            return ControlMasterState(
                enabled: false,
                status: .disabled,
                controlPath: effective.first("controlpath"),
                lastCheckedAt: Date()
            )
        }

        let result = try await sshRunner.ssh(arguments: ["-O", "check", alias], environment: env)
        let now = Date()
        let socketURL = URL(fileURLWithPath: NSString(string: socketPath).expandingTildeInPath)
        let socketExists = FileManager.default.fileExists(atPath: socketURL.path)

        if result.exitCode == 0 || SSHCheckParser.indicatesMasterRunning(result.stderr) {
            let pid = SSHCheckParser.parseMasterPid(result.stderr)
            // Prefer the socket file's birthtime (st_birthtimespec) as
            // the master's established-at — it's kernel truth, survives
            // Bastion restart, and works for masters not spawned by
            // Bastion (e.g. user opened a manual `ssh -fNM` from CLI).
            // Falls back to first-observed-at if stat fails.
            let birthtime = SocketBirthtime.lookup(path: socketURL.path)
            let observedAt = birthtime ?? now
            let established = masterUptimeStore.recordSeen(alias: alias, at: observedAt)
            let channels = await channelProbe.count(socketPath: socketURL.path, masterPid: pid)
            return ControlMasterState(
                enabled: true,
                status: .running,
                controlPath: socketURL.path,
                pid: pid,
                establishedAt: established,
                attachedSessions: channels?.count,
                persistSeconds: persistSeconds(from: effective),
                lastCheckedAt: now
            )
        }
        if socketExists {
            return ControlMasterState(
                enabled: true,
                status: .stale,
                controlPath: socketURL.path,
                persistSeconds: persistSeconds(from: effective),
                lastCheckedAt: now
            )
        }
        masterUptimeStore.clear(alias: alias)
        return ControlMasterState(
            enabled: true,
            status: .down,
            controlPath: socketURL.path,
            persistSeconds: persistSeconds(from: effective),
            lastCheckedAt: now
        )
    }

    /// `ssh -O exit <alias>`. Idempotent — non-zero exit is reported but
    /// not raised (it's typical for the master to already be gone).
    @discardableResult
    public func stopMaster(_ alias: String) async throws -> SSHRunResult {
        let env = pathResolver.environment()
        let result = try await sshRunner.ssh(arguments: ["-O", "exit", alias], environment: env)
        masterUptimeStore.clear(alias: alias)
        return result
    }

    /// Establish a master in the background (`ssh -fNM -o BatchMode=yes
    /// <alias>`). Only succeeds when the user's keys are already
    /// authenticated (loaded in agent or no passphrase) — otherwise
    /// returns the BatchMode failure and the caller should fall back to
    /// opening a terminal foreground session (consensus §5 §8).
    @discardableResult
    public func establishBackgroundMaster(_ alias: String) async throws -> SSHRunResult {
        let env = pathResolver.environment()
        return try await sshRunner.ssh(
            arguments: ["-fNM", "-o", "BatchMode=yes", alias],
            environment: env
        )
    }

    /// Same as `establishBackgroundMaster` but with a hard timeout that
    /// actually kills the spawned ssh subprocess. Used by the FIDO
    /// fast-path: try a cached-cred bootstrap first; on timeout, fall
    /// through to the foreground terminal launch.
    ///
    /// **Why subprocess-killing matters**: per rubber-duck pass, Swift
    /// Task.cancel() is cooperative. A naive timeout that just stops
    /// awaiting would leave the BatchMode probe running. If it succeeds
    /// 100ms after we already launched the foreground `ssh -fNM`, two
    /// masters race for the same socket; the user wastes a FIDO touch.
    /// `ProcessTimeout.run` owns the Process and SIGTERMs / SIGKILLs it
    /// before returning.
    ///
    /// Returns nil on timeout (treat as "no fast-path"); returns the
    /// run result on completion (caller checks `exitCode == 0`).
    public func establishBackgroundMasterWithTimeout(
        _ alias: String,
        timeout: TimeInterval = 2.0
    ) async -> ProcessRunResult? {
        // Belt-and-suspenders: ensure ~/.ssh/sockets/ exists. The writer
        // creates it on every save, but a host may have been added by a
        // prior version (or the user may have deleted the dir manually).
        // Without the parent dir, ssh succeeds at auth but silently
        // fails to bind the socket, which the user sees as a 180s hang.
        try? Paths.ensureSocketsDirectoryExists()
        let env = pathResolver.environment()
        // -o ConnectTimeout caps the TCP-connect phase server-side; the
        // Task-level timeout caps the post-connect (auth) phase. Belt+suspenders.
        let result = await ProcessTimeout.run(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: ["-fNM",
                        "-o", "BatchMode=yes",
                        "-o", "ConnectTimeout=2",
                        alias],
            environment: env,
            timeout: timeout
        )
        return result.timedOut ? nil : result
    }

    /// Outcome of `awaitMaster` polling. Richer than the previous Bool
    /// so the connect flow can produce diagnostic chips per outcome
    /// (consensus + rubber-duck: "failure must be diagnostic").
    public enum AwaitMasterOutcome: Equatable, Sendable {
        case alive
        case timeout
        case staleAfterHeal(socket: String)   // stale socket healed once but came back stale
        case preflightFailed(String)          // ssh -G says no master configured for this alias

        public var description: String {
            switch self {
            case .alive:                       return "alive"
            case .timeout:                     return "timeout"
            case .staleAfterHeal(let s):       return "stale-after-heal(\(s))"
            case .preflightFailed(let r):      return "preflight-failed(\(r))"
            }
        }
    }

    /// Poll `ssh -O check` until the master comes up or the deadline
    /// passes. Used by the connect-with-bootstrap flow to detect when
    /// the user has completed the FIDO/SSO dance in their terminal.
    /// Returns a rich outcome instead of a Bool so the chip can diagnose.
    ///
    /// Self-heals a stale socket once per call (some sockets are left
    /// behind by killed previous masters; without removing them the new
    /// master can't bind). Limited to once per call to prevent an
    /// infinite delete-respawn loop if a buggy server keeps marking
    /// the socket dead.
    public func awaitMaster(
        _ alias: String,
        timeout: TimeInterval = 180,
        pollInterval: TimeInterval = 1
    ) async -> AwaitMasterOutcome {
        // Pre-flight: if the configured ControlPath's parent dir doesn't
        // exist, polling will never succeed because OpenSSH won't create
        // it. Surface immediately so the user gets an actionable chip
        // within ~500ms instead of waiting 180s for "auth didn't
        // complete". Cheap to evaluate (one ssh -G + one stat).
        if let cfg = try? await reader.effectiveConfig(forAlias: alias),
           let socketPath = cfg.usableControlPath {
            let expanded = NSString(string: socketPath).expandingTildeInPath
            let parent = (expanded as NSString).deletingLastPathComponent
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: parent, isDirectory: &isDir)
            if !exists || !isDir.boolValue {
                // Try a one-shot recovery: many users hit this because
                // the dir was deleted between a save and a connect, or
                // because they're on a brand-new install whose first
                // save predated this fix. If we can mkdir it, do so and
                // continue polling instead of failing the user's flow.
                try? Paths.ensureSocketsDirectoryExists()
                let recovered = FileManager.default.fileExists(atPath: parent, isDirectory: &isDir) && isDir.boolValue
                if !recovered {
                    return .preflightFailed("ControlPath parent dir \(parent) doesn't exist and couldn't be created")
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var healedOnce = false
        while Date() < deadline {
            let state = (try? await checkMaster(alias))
                        ?? ControlMasterState(status: .unknown)
            switch state.status {
            case .running:
                return .alive
            case .disabled:
                // Effective config has ControlMaster disabled — polling
                // will never succeed. Bail with a diagnostic.
                return .preflightFailed("ControlMaster disabled in effective config")
            case .stale where !healedOnce:
                healedOnce = true
                if let path = state.controlPath {
                    try? FileManager.default.removeItem(
                        atPath: NSString(string: path).expandingTildeInPath
                    )
                }
                // Fall through to sleep + re-poll.
            case .stale:
                return .staleAfterHeal(socket: state.controlPath ?? "?")
            default:
                break
            }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        return .timeout
    }

    /// `ssh -o BatchMode=yes -o ConnectTimeout=5 <alias> true`. Used by
    /// the "Test connection" UI affordance; opt-in default-off per
    /// consensus (may show in remote auth logs).
    public func testConnection(_ alias: String) async throws -> SSHRunResult {
        let env = pathResolver.environment()
        return try await sshRunner.ssh(
            arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", alias, "true"],
            environment: env
        )
    }

    // MARK: - Status snapshot

    /// Build a complete StatusReport. The menu app polls this every
    /// 5s while popover open / 30s closed; the CLI's
    /// `bastion status --json` shells out and returns it.
    ///
    /// Selective polling (rubber-duck): we resolve effective config for
    /// every host but only run `ssh -O check` for hosts whose
    /// `controlmaster` is enabled AND have a usable ControlPath.
    public func snapshot(appVersion: String) async -> StatusReport {
        let registry = (try? store.load()) ?? HostRegistry()
        let scan = (try? scanner.scan()) ?? UserSSHConfigScan(
            sentinelInstalled: false, existingHostAliases: [],
            coveringIncludePresent: false, hasMatchExec: false,
            isEmpty: true, resolvedSymlinkTarget: nil
        )
        let agent = agentProbe.detect()
        let sshVersion = await sshBinaryVersion()
        let iCloudSuspected = HostFingerprint.suspectsSync(fileManager: .default)

        var snapshots: [HostSnapshot] = []
        for host in registry.hosts {
            let snapshot = await snapshotForHost(host)
            snapshots.append(snapshot)
        }
        return StatusReport(
            appVersion: appVersion,
            sshBinaryVersion: sshVersion,
            agentReachable: agent != .unavailable,
            oneOnePasswordAgentDetected: agent == .onePassword,
            defaultTerminal: nil,            // wired up in commit 7
            includeInstalled: scan.sentinelInstalled || scan.coveringIncludePresent,
            hosts: snapshots,
            terminals: [],                   // wired up in commit 7
            iCloudSyncSuspected: iCloudSuspected,
            generatedAt: Date()
        )
    }

    private func snapshotForHost(_ host: ManagedHost) async -> HostSnapshot {
        let cm = (try? await checkMaster(host.alias)) ?? ControlMasterState(status: .unknown)
        return HostSnapshot(
            id: host.id,
            alias: host.alias,
            hostname: host.hostname,
            user: host.user,
            port: host.port,
            identityFiles: host.identityFiles,
            source: .managed,
            controlMaster: cm,
            uptimeSeconds: cm.establishedAt.map { Int(Date().timeIntervalSince($0)) },
            requiresInteractiveAuth: host.requiresInteractiveAuth
        )
    }

    private func sshBinaryVersion() async -> String? {
        let result = try? await sshRunner.ssh(arguments: ["-V"], environment: pathResolver.environment())
        guard let result else { return nil }
        // `ssh -V` writes to stderr.
        let raw = result.stderr.isEmpty ? result.stdout : result.stderr
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func persistSeconds(from cfg: EffectiveConfig) -> Int? {
        guard let raw = cfg.first("controlpersist")?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if raw == "yes" { return 0 }
        if raw == "no"  { return 0 }
        if let n = Int(raw) { return n }
        return nil
    }
}

/// Per-host "first time we saw it alive" timestamps. Persisted to
/// `status-cache.json` so master uptime survives menu app restarts.
public final class MasterUptimeStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: Date] = [:]

    public init() {
        loadFromDisk()
    }

    @discardableResult
    public func recordSeen(alias: String, at date: Date) -> Date? {
        lock.lock(); defer { lock.unlock() }
        // If we have an older established-at on file, keep it — unless
        // the supplied date is earlier (e.g. socket birthtime is older
        // than our cached first-observed). This handles app restart:
        // socket was created an hour ago, our cache says we just saw
        // it; the *real* established-at is the older birthtime.
        if let existing = cache[alias], existing <= date { return existing }
        cache[alias] = date
        persistToDisk()
        return date
    }

    public func clear(alias: String) {
        lock.lock(); defer { lock.unlock() }
        cache.removeValue(forKey: alias)
        persistToDisk()
    }

    public func establishedAt(alias: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return cache[alias]
    }

    private struct CachePayload: Codable {
        var schemaVersion: Int
        var establishedAt: [String: Date]
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: Paths.statusCacheFile.path) else { return }
        guard let data = try? Data(contentsOf: Paths.statusCacheFile) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let payload = try? decoder.decode(CachePayload.self, from: data) {
            cache = payload.establishedAt
        }
    }

    private func persistToDisk() {
        try? Paths.ensureAppSupportDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = CachePayload(schemaVersion: 1, establishedAt: cache)
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: Paths.statusCacheFile, options: .atomic)
    }
}

/// Detects whether `~/.ssh` looks like it's syncing across Macs (iCloud
/// Drive, Resilio, etc) — per rubber-duck B1/N1 and consensus §15.
/// Writes a `.bastion-host-fingerprint` file containing our hostname +
/// hardware UUID; on subsequent launches a mismatch means another Mac
/// wrote it.
public enum HostFingerprint {
    public static func suspectsSync(fileManager: FileManager) -> Bool {
        let current = currentFingerprint()
        let file = Paths.hostFingerprintFile
        guard fileManager.fileExists(atPath: file.path) else {
            // First run on this machine: write and return false.
            try? Paths.ensureAppSupportDirectoryExists()
            try? Data(current.utf8).write(to: file, options: .atomic)
            return false
        }
        guard let data = try? Data(contentsOf: file),
              let stored = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return stored != current
    }

    static func currentFingerprint() -> String {
        let host = ProcessInfo.processInfo.hostName
        // Hardware UUID via IOPlatformExpertDevice
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        task.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        var hwUUID = "unknown-hw"
        if (try? task.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if let output = String(data: data, encoding: .utf8) {
                for line in output.split(separator: "\n") {
                    if line.contains("IOPlatformUUID") {
                        let parts = line.split(separator: "=")
                        if parts.count == 2 {
                            hwUUID = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                            break
                        }
                    }
                }
            }
        }
        return "\(host)\t\(hwUUID)"
    }
}
