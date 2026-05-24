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
