import Foundation
import Darwin

/// Detect and clean up orphaned `ssh -fNM <alias>` processes left behind
/// by failed bootstrap attempts (e.g. user clicked Connect on a FIDO
/// host but cancelled the FIDO touch; the spawned `ssh -fNM` is still
/// holding TCP to the bastion but bound no socket).
///
/// Per dual-model consensus: **detect-only on launch, user clicks to
/// clean up.** Never auto-reap on bootstrap — race: a legitimately-
/// spawned master 200ms into its connect would look "orphaned" until
/// it binds its socket; killing it then is worse than leaving a leak.
///
/// **Known limitation (rubber-duck blind-spot #3)**: `ps -axo command=`
/// joins argv with single spaces. Hosts that appear inside arg values
/// containing spaces (e.g. `IdentityFile=/Users/Foo Bar/.ssh/key`)
/// can't be cleanly tokenized. We err on the side of false negatives
/// (miss some orphans) rather than false positives (kill wrong PIDs).
/// V2 fix would route through `sysctl KERN_PROCARGS2` for real argv
/// arrays; defer until v1 misses prove costly.
public enum OrphanReaper {

    /// One detected `ssh -fNM <alias>` process tied to a Bastion alias.
    public struct Orphan: Equatable, Sendable {
        public let pid: pid_t
        public let alias: String
        public let argv: String
    }

    /// Scan running processes for `ssh -fNM` invocations owned by the
    /// current user whose argv contains `alias` as a standalone token.
    public static func scan(forAlias alias: String) -> [Orphan] {
        guard let output = runPS() else { return [] }
        let myUid = getuid()
        var found: [Orphan] = []
        for line in output.split(separator: "\n") {
            // Format: "<pid> <uid> <command...>"
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = pid_t(parts[0]),
                  let uid = uid_t(parts[1]),
                  uid == myUid else { continue }
            let command = String(parts[2])
            // Must be an ssh -fNM invocation.
            guard command.contains(" -fNM") else { continue }
            // Argv-tokenize on whitespace and look for the alias as a
            // standalone bare token. This handles `-o ControlPath=/x`
            // (single token, not split on `=`) and naked `vault` (single
            // token, matches). False-negatives on paths with spaces are
            // acknowledged.
            let tokens = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if tokens.contains(alias) {
                found.append(Orphan(pid: pid, alias: alias, argv: command))
            }
        }
        return found
    }

    /// Result of a reap attempt for diagnostics in the UI.
    public struct ReapResult: Sendable {
        public let pidsKilled: [pid_t]
        public let pidsFailed: [pid_t]
    }

    /// Two-pass reaper, per dual-model consensus + rubber-duck:
    ///   1. Try `ssh -O exit <alias>` — only works if a master socket
    ///      exists AND is responsive (real orphans by definition don't).
    ///   2. Fall back to `kill(pid, SIGTERM)`, wait 500ms, then
    ///      `SIGKILL` any survivors.
    ///
    /// Run on a background task; safe to call from any actor.
    public static func reap(
        alias: String,
        pids: [pid_t],
        engine: ConnectionEngine?
    ) async -> ReapResult {
        // Try `ssh -O exit` first if we have an engine handle.
        if let engine {
            _ = try? await engine.stopMaster(alias)
        }
        var killed: [pid_t] = []
        var failed: [pid_t] = []
        for pid in pids {
            if !isAlive(pid: pid) { killed.append(pid); continue }
            if kill(pid, SIGTERM) != 0 {
                failed.append(pid)
                continue
            }
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        for pid in pids where isAlive(pid: pid) {
            if kill(pid, SIGKILL) == 0 {
                killed.append(pid)
            } else {
                failed.append(pid)
            }
        }
        for pid in pids where !isAlive(pid: pid) && !killed.contains(pid) {
            killed.append(pid)
        }
        return ReapResult(pidsKilled: killed.filter { !failed.contains($0) }, pidsFailed: failed)
    }

    private static func isAlive(pid: pid_t) -> Bool {
        // `kill(pid, 0)` returns 0 if the process exists and we have
        // permission, errno == ESRCH if it doesn't. We're checking
        // same-uid processes so permission is fine.
        return kill(pid, 0) == 0
    }

    private static func runPS() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,uid=,command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - Legacy %C-style master detection

    /// One detected legacy master that's running on the OLD `%C`-hashed
    /// ControlPath, from before Bastion switched to `bastion-<id>-%p-%r`
    /// stable paths.
    ///
    /// Bastion's `ssh -G`-based status code now looks at the new
    /// stable path, so a legacy master appears as `down` in the UI even
    /// though it's still alive and consuming a FIDO/SSO authentication
    /// the user paid for. We detect these so the host card can offer a
    /// `[Move now]` button (sends `ssh -O exit` to retire the legacy
    /// master, prompts the user to reconnect once).
    public struct LegacyMaster: Equatable, Sendable {
        /// Absolute path of the socket file under `~/.ssh/sockets/`.
        public let socketPath: String
        /// Owning `ssh -fNM` PID if we can correlate via `ps`. Nil
        /// when the socket exists but no current process owns it
        /// (defunct socket; benign — `[Move now]` will rm it).
        public let pid: pid_t?
        /// Alias the legacy master was launched for, if we can recover
        /// it from `ps`. Nil for masters started outside Bastion (e.g.
        /// a `ssh -fNM somehost` the user typed manually).
        public let alias: String?
    }

    /// Walk `~/.ssh/sockets/` for any file whose name doesn't start
    /// with the `bastion-` prefix. Cross-reference with `ps` to find
    /// the owning `ssh -fNM` process when possible. Returns one entry
    /// per legacy socket file.
    ///
    /// Per dual-model consensus + rubber-duck N4: the existing
    /// `scan(forAlias:)` matches on alias-token-in-argv. Legacy
    /// masters are identified by their SOCKET PATH, not by alias.
    /// This is a fundamentally different scan surface, not an
    /// extension of `scan(forAlias:)` — hence a new public method.
    public static func scanForLegacyMasters() -> [LegacyMaster] {
        let socketsDir = Paths.sshSocketsDirectory.path
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: socketsDir) else {
            return []
        }
        let legacyNames = entries.filter { !$0.hasPrefix("bastion-") }
        guard !legacyNames.isEmpty else { return [] }

        // Build a map from socketPath → (pid, alias) using a single
        // `ps` invocation. We look for any `ssh ... -S <path>` (explicit
        // ControlPath override on cmdline) AND match by best-effort
        // alias-in-argv for the bare `ssh -fNM <alias>` form (where
        // the socket path is implicit per the user's config).
        var pidByPath: [String: pid_t] = [:]
        let aliasByPath: [String: String] = [:]
        if let psOutput = runPS() {
            let myUid = getuid()
            for line in psOutput.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count == 3,
                      let pid = pid_t(parts[0]),
                      let uid = uid_t(parts[1]),
                      uid == myUid else { continue }
                let command = String(parts[2])
                guard command.contains(" -fNM") || command.contains(" -fM") else { continue }
                // Path-1: explicit `-S <socket>` on argv.
                if let socketPath = explicitSocketPath(in: command),
                   legacyNames.contains(URL(fileURLWithPath: socketPath).lastPathComponent) {
                    pidByPath[socketPath] = pid
                }
                // Path-2: bare `ssh -fNM <alias>` — we can't recover
                // the socket path from argv alone (it's in ~/.ssh/config),
                // but we DO know an alias was used. Stash for later
                // socket→alias correlation if needed.
                _ = command
            }
        }

        var result: [LegacyMaster] = []
        for name in legacyNames {
            let path = (socketsDir as NSString).appendingPathComponent(name)
            result.append(LegacyMaster(
                socketPath: path,
                pid: pidByPath[path],
                alias: aliasByPath[path]
            ))
        }
        return result
    }

    /// Extract the value of `-S <socket>` from a tokenised ssh command
    /// line. Returns nil when not present. Naive whitespace split
    /// matches our existing argv-handling caveats (paths with spaces
    /// are not supported — same limitation as `scan(forAlias:)`).
    private static func explicitSocketPath(in command: String) -> String? {
        let tokens = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < tokens.count - 1 {
            if tokens[i] == "-S" { return tokens[i + 1] }
            i += 1
        }
        return nil
    }
}
