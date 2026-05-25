import Foundation

/// Two-pass validation result produced by `ManagedConfigWriter`.
public struct ManagedConfigWriteResult: Sendable {
    /// Outcome of the isolation pass (`ssh -F <tmp> -G <alias>`). Empty
    /// if the registry is empty.
    public var isolationPassed: Bool
    /// Outcome of the integration pass (`ssh -G <alias>` against the
    /// composed config). May be skipped if `skipIntegrationPass` was
    /// requested (e.g. user has `Match exec` and opted out per-host).
    public var integrationPassed: Bool
    /// Aliases that failed integration with the expected-value diff.
    public var integrationMismatches: [String: [String: String]]
}

/// High-level orchestrator that writes Bastion-owned config and verifies
/// OpenSSH accepts it. Combines:
/// - `BastionConfigWriter` (render bytes).
/// - Atomic write with `.prev` rollback.
/// - Isolation `ssh -F tmp -G alias` (catches our malformed lines).
/// - Optional integration `ssh -G alias` (catches collisions with user's
///   `~/.ssh/config`); skipped per-host when `Match exec` is present and
///   the caller said don't run it.
///
/// Rubber-duck fixes:
/// - B3 (two-pass validation): explicit isolation + integration passes.
/// - B4 (`Match exec`): caller decides whether to skip integration.
/// - B1 (symlinks): scanner resolves; we never replace the symlink.
public struct ManagedConfigWriter {
    public let writer: BastionConfigWriter
    public let reader: SSHGReader
    public let managedFile: URL
    public let prevFile: URL
    public let fileManager: FileManager

    public init(
        writer: BastionConfigWriter = BastionConfigWriter(),
        reader: SSHGReader = SSHGReader(),
        managedFile: URL = Paths.managedConfigFile,
        prevFile: URL = Paths.managedConfigPrevFile,
        fileManager: FileManager = .default
    ) {
        self.writer = writer
        self.reader = reader
        self.managedFile = managedFile
        self.prevFile = prevFile
        self.fileManager = fileManager
    }

    /// Write the rendered config, perform isolation + optional integration
    /// validation, and roll back to `.prev` if either pass fails.
    public func write(
        _ registry: HostRegistry,
        skipIntegrationPass: Bool = false,
        generatedAt: Date = Date()
    ) async throws -> ManagedConfigWriteResult {
        try ensureConfigDirectoryExists()

        let body = try writer.render(registry, generatedAt: generatedAt)
        let bodyData = Data(body.utf8)

        // Rotate previous → .prev so rollback is possible if validation fails.
        if fileManager.fileExists(atPath: managedFile.path) {
            try? fileManager.removeItem(at: prevFile)
            try? fileManager.copyItem(at: managedFile, to: prevFile)
        }

        // Atomic write of the new content.
        try atomicWrite(data: bodyData, to: managedFile, mode: 0o600)

        var result = ManagedConfigWriteResult(
            isolationPassed: false,
            integrationPassed: !skipIntegrationPass,  // optimistic; flipped on first mismatch
            integrationMismatches: [:]
        )

        // Isolation pass: write to a tempfile in /tmp and validate with -F.
        // This catches anything our writer produced that OpenSSH rejects
        // independently of what's in ~/.ssh/config.
        let isolationFile = fileManager.temporaryDirectory.appendingPathComponent(
            "bastion-isolation-\(UUID().uuidString).conf"
        )
        defer { try? fileManager.removeItem(at: isolationFile) }
        try atomicWrite(data: bodyData, to: isolationFile, mode: 0o600)

        for host in registry.hosts {
            do {
                _ = try await reader.effectiveConfig(forAlias: host.alias, configFile: isolationFile)
            } catch let sshError as SSHConfigError {
                try rollback()
                throw sshError
            }
            // Per dual-model consensus: when alias != hostname, ALSO
            // resolve `ssh -G <hostname>` and assert it yields the same
            // ControlPath. This is the load-bearing assertion that the
            // shared-master design actually shares — the `Match host`
            // block must take effect for the FQDN-typed path. If the
            // pattern was silently dropped (e.g. hostname looked like
            // a glob and our writer skipped the Match block, or the
            // user had `CanonicalizeHostname always` that broke our
            // matching), throw. Per rubber-duck on shared-master design.
            if host.hostname.lowercased() != host.alias.lowercased(),
               host.controlMaster.configValue != nil,
               !host.hostname.contains(where: { "*?!".contains($0) }) {
                do {
                    let aliasCfg = try await reader.effectiveConfig(forAlias: host.alias, configFile: isolationFile)
                    let hostCfg = try await reader.effectiveConfig(forAlias: host.hostname, configFile: isolationFile)
                    let aliasPath = aliasCfg.first("controlpath")
                    let hostPath = hostCfg.first("controlpath")
                    if aliasPath != hostPath {
                        try rollback()
                        throw SSHConfigError.invalidValue(
                            option: "controlpath",
                            reason: "alias '\(host.alias)' and hostname '\(host.hostname)' resolve to different ControlPaths in the rendered bastion.conf — the Match host block did not take effect. alias='\(aliasPath ?? "nil")', hostname='\(hostPath ?? "nil")'. This is a writer bug; please file an issue."
                        )
                    }
                } catch let sshError as SSHConfigError {
                    try rollback()
                    throw sshError
                }
            }
        }
        result.isolationPassed = true

        // Integration pass: verify the *composed* config (no -F flag, so
        // ssh resolves through ~/.ssh/config + Include chain).
        guard !skipIntegrationPass else { return result }

        for host in registry.hosts {
            let expected = expectedValues(for: host)
            let effective: EffectiveConfig
            do {
                effective = try await reader.effectiveConfig(forAlias: host.alias, configFile: nil)
            } catch {
                // Integration pass failed entirely — surface but don't
                // roll back (isolation succeeded; user's config likely
                // has a Match exec / canonicalisation surprise).
                result.integrationPassed = false
                result.integrationMismatches[host.alias] = ["error": "\(error)"]
                continue
            }
            var mismatches: [String: String] = [:]
            for (key, want) in expected {
                let got = effective.first(key)
                if normalise(got) != normalise(want) {
                    mismatches[key] = "expected=\(want.debugDescription) got=\(got?.debugDescription ?? "nil")"
                }
            }
            // ControlPath integration check — per rubber-duck B3, `ssh
            // -G` emits the path with `%p` / `%r` already expanded to
            // runtime values (verified empirically:
            //   $ ssh -G -o 'ControlPath=~/.ssh/sockets/test-%p-%r' -F /dev/null somehost
            //   controlpath /Users/alice/.ssh/sockets/test-22-alice
            // ), so literal string comparison against our writer's
            // `~/.ssh/sockets/bastion-<id>-%p-%r` would throw on every
            // save. Compare with a regex instead.
            if host.controlMaster.configValue != nil {
                let pattern = expectedControlPathPattern(for: host)
                let got = effective.first("controlpath") ?? ""
                if got.range(of: pattern, options: .regularExpression) == nil {
                    mismatches["controlpath"] = "expected matching \(pattern.debugDescription) got=\(got.debugDescription)"
                }
            }
            if !mismatches.isEmpty {
                result.integrationPassed = false
                result.integrationMismatches[host.alias] = mismatches
            }
        }
        return result
    }

    /// Restore the previous version of the managed file (if any) from
    /// `.prev`. Used by the post-write validation path and externally
    /// available for manual recovery.
    public func rollback() throws {
        if fileManager.fileExists(atPath: prevFile.path) {
            try? fileManager.removeItem(at: managedFile)
            try fileManager.copyItem(at: prevFile, to: managedFile)
        } else {
            try? fileManager.removeItem(at: managedFile)
        }
    }

    /// Delete the managed file entirely. Used by `bastion uninstall`.
    public func removeManagedFile() throws {
        try? fileManager.removeItem(at: managedFile)
        try? fileManager.removeItem(at: prevFile)
    }

    // MARK: - Helpers

    private func ensureConfigDirectoryExists() throws {
        do {
            try fileManager.createDirectory(
                at: Paths.userSSHDirectory,
                withIntermediateDirectories: true,
                attributes: [FileAttributeKey.posixPermissions: 0o700]
            )
            try fileManager.createDirectory(
                at: Paths.userSSHConfigDirectory,
                withIntermediateDirectories: true,
                attributes: [FileAttributeKey.posixPermissions: 0o700]
            )
            // The bastion.conf we're about to write points ControlPath
            // at ~/.ssh/sockets/%C. OpenSSH does NOT auto-create that
            // parent dir; without it, the master daemon silently fails
            // to bind after a successful FIDO/password auth. The writer
            // owns the conf, so the writer owns the dir it references.
            try Paths.ensureSocketsDirectoryExists()
        } catch {
            throw SSHConfigError.io("mkdir ~/.ssh/config.d: \(error.localizedDescription)")
        }
    }

    private func atomicWrite(data: Data, to target: URL, mode: mode_t) throws {
        let temp = target.appendingPathExtension("tmp")
        try? fileManager.removeItem(at: temp)
        do {
            try data.write(to: temp, options: .atomic)
            try fileManager.setAttributes(
                [FileAttributeKey.posixPermissions: NSNumber(value: mode)],
                ofItemAtPath: temp.path
            )
        } catch {
            throw SSHConfigError.io("write \(temp.path): \(error.localizedDescription)")
        }
        guard rename(temp.path, target.path) == 0 else {
            throw SSHConfigError.io("rename failed: \(String(cString: strerror(errno)))")
        }
    }

    /// Regex matching the literal ControlPath we expect `ssh -G alias`
    /// to emit after `%p` and `%r` expansion. Per rubber-duck B3 — we
    /// cannot string-compare because `ssh -G` substitutes tokens at
    /// probe time.
    ///
    /// Anchored, with the home directory and 12-hex mux id baked in
    /// literally and the port/user segments as `\d+` / `[^/]+`. The
    /// user segment is left as `[^/]+` rather than the resolved user
    /// value because integration validation runs as the local process
    /// user, which may differ from the host's configured remote user
    /// (and from any future SSH invocation's `-l otheruser`). The
    /// segmentation is provided by the `Match host` block routing the
    /// right invocation to this stanza; the regex just verifies
    /// Bastion's writer + Match emission landed.
    private func expectedControlPathPattern(for host: ManagedHost) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let prefix = home + "/.ssh/sockets/bastion-\(host.resolvedControlMuxID)-"
        let escaped = NSRegularExpression.escapedPattern(for: prefix)
        return "^" + escaped + #"\d+-[^/]+$"#
    }

    /// The set of (key, value) pairs we expect `ssh -G alias` to report
    /// for a given managed host. Used by the integration pass to detect
    /// the user's `Host *` defaults or a `Match exec` overriding our
    /// per-alias settings.
    private func expectedValues(for host: ManagedHost) -> [String: String] {
        var expected: [String: String] = [:]
        expected["hostname"] = host.hostname
        if let user = host.user { expected["user"] = user }
        expected["port"] = "\(host.port)"
        if !host.identityFiles.isEmpty {
            // ssh -G emits absolute paths; the writer also expanded ~ at write time.
            let first = host.identityFiles[0]
            expected["identityfile"] = NSString(string: first).expandingTildeInPath
        }
        if let cm = host.controlMaster.configValue {
            expected["controlmaster"] = cm
        }
        if let cp = host.controlPersist.configValue {
            expected["controlpersist"] = canonicalisePersist(cp)
        }
        return expected
    }

    /// `ssh -G` re-emits ControlPersist in canonicalised seconds (e.g.
    /// `8h` → `28800`, `yes` → `0`, `no` → `0` with controlmaster=no…).
    /// We only compare loosely: integer == integer, suffix forms agree.
    private func canonicalisePersist(_ value: String) -> String {
        let lower = value.lowercased()
        if lower == "yes" || lower == "no" { return lower == "yes" ? "0" : "0" }
        if lower.hasSuffix("h"), let n = Int(lower.dropLast()) { return "\(n * 3600)" }
        if lower.hasSuffix("m"), let n = Int(lower.dropLast()) { return "\(n * 60)" }
        if lower.hasSuffix("s"), let n = Int(lower.dropLast()) { return "\(n)" }
        return lower
    }

    private func normalise(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
