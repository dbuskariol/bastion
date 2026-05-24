import Foundation

/// Renders a `HostRegistry` to the textual `~/.ssh/config.d/bastion.conf`
/// shape. Bastion is the sole writer of that file; the format is a
/// deliberately constrained subset of `ssh_config(5)` so we never have to
/// round-trip arbitrary user input. Per consensus: byte-deterministic,
/// idempotent, atomic write, two-pass `ssh -G` validation (next file).
public struct BastionConfigWriter {
    public init() {}

    /// Render the registry to the bytes that should be persisted as
    /// `bastion.conf`. The output is deterministic (no timestamps in the
    /// body, fixed key order) so two saves of the same registry produce
    /// byte-identical files. The header has the generated-at timestamp
    /// but lives above the first `Host` stanza so the body diff stays
    /// quiet across saves.
    public func render(_ registry: HostRegistry, generatedAt: Date = Date()) throws -> String {
        try validate(registry)
        var lines: [String] = []
        lines.append(contentsOf: headerLines(generatedAt: generatedAt))
        let sortedHosts = registry.hosts.sorted { $0.alias.lowercased() < $1.alias.lowercased() }
        for host in sortedHosts {
            lines.append("")
            lines.append(contentsOf: try stanzaLines(for: host))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Header

    private func headerLines(generatedAt: Date) -> [String] {
        let stamp = ISO8601DateFormatter().string(from: generatedAt)
        return [
            "# Bastion — generated file. Do not edit by hand; changes are overwritten on every save.",
            "# Source of truth: ~/Library/Application Support/Bastion/hosts.json",
            "# Generated at: \(stamp)"
        ]
    }

    // MARK: - Per-host stanza

    private func stanzaLines(for host: ManagedHost) throws -> [String] {
        var lines: [String] = []
        lines.append("Host \(host.alias)")
        // Stable comment so we can attribute lines back to the registry id.
        lines.append("    # id: \(host.id.uuidString)")
        lines.append("    \(SSHOption.identityFile.configKey == "IdentityFile" ? "HostName" : "HostName") \(try checked(host.hostname))")
        if let user = host.user, !user.isEmpty {
            lines.append("    User \(try checked(user))")
        }
        if host.port != 22 {
            lines.append("    Port \(host.port)")
        }

        for path in host.identityFiles {
            lines.append("    \(SSHOption.identityFile.configKey) \(try checked(expandTilde(path)))")
        }
        if !host.identityFiles.isEmpty {
            // Setting IdentitiesOnly=yes when we provide explicit
            // identity files is industry-standard: without it, the
            // running ssh-agent will offer every key it holds and trip
            // server-side MaxAuthTries before our intended key is tried.
            lines.append("    IdentitiesOnly yes")
        }

        if let value = host.controlMaster.configValue {
            lines.append("    \(SSHOption.controlMaster.configKey) \(value)")
            // ControlPath always points to the consensus default; users
            // can override via Raw if they really need a custom path.
            lines.append("    \(SSHOption.controlPath.configKey) ~/.ssh/sockets/%C")
        }
        // ControlPersist: if user picked Inherit but ControlMaster is .on,
        // upgrade silently to the default (.hours(8)). An On-master with
        // no persist is just an in-session master that dies with the
        // shell — which defeats the entire "unlock for the day" UX.
        let effectivePersist: ControlPersistChoice = {
            if case .inherit = host.controlPersist, host.controlMaster == .on {
                return .defaultChoice
            }
            return host.controlPersist
        }()
        if let value = effectivePersist.configValue {
            lines.append("    \(SSHOption.controlPersist.configKey) \(value)")
        }

        // Advanced options — fixed key order for deterministic output.
        let advancedOrder: [SSHOption] = [
            .serverAliveInterval, .serverAliveCountMax, .tcpKeepAlive,
            .addKeysToAgent, .useKeychain, .preferredAuthentications,
            .identityAgent, .certificateFile, .pkcs11Provider, .securityKeyProvider,
            .addressFamily, .connectTimeout, .connectionAttempts,
            .bindAddress, .bindInterface,
            .canonicalizeHostname, .canonicalDomains,
            .localForward, .remoteForward, .dynamicForward,
            .gatewayPorts, .exitOnForwardFailure,
            .proxyJump, .proxyCommand,
            .strictHostKeyChecking, .userKnownHostsFile, .checkHostIP,
            .hashKnownHosts, .verifyHostKeyDNS, .updateHostKeys, .visualHostKey,
            .hostKeyAlgorithms, .kexAlgorithms, .ciphers, .macs, .pubkeyAcceptedAlgorithms,
            .requestTTY, .remoteCommand, .sendEnv, .setEnv,
            .logLevel, .compression, .sessionType, .ipQoS,
            .forwardAgent,
            .kbdInteractiveAuthentication, .kbdInteractiveDevices, .passwordAuthentication,
            .tag
        ]
        for option in advancedOrder {
            guard let value = host.advanced[option] else { continue }
            try guardValue(value, option: option.configKey)
            lines.append("    \(option.configKey) \(value)")
        }

        if let raw = host.rawConfigOverride, !raw.isEmpty {
            try guardRawOverride(raw)
            lines.append("    # ---- Raw override (user-supplied) ----")
            for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("    \(rawLine)")
            }
        }
        return lines
    }

    // MARK: - Validation

    private func validate(_ registry: HostRegistry) throws {
        var seenAliases: Set<String> = []
        for host in registry.hosts {
            guard Alias.isValid(host.alias) else {
                throw SSHConfigError.invalidAlias(host.alias)
            }
            let lowered = host.alias.lowercased()
            if seenAliases.contains(lowered) {
                throw SSHConfigError.invalidAlias("duplicate \(host.alias)")
            }
            seenAliases.insert(lowered)
        }
    }

    private func checked(_ value: String) throws -> String {
        try guardValue(value, option: "value")
        return value.contains(" ") || value.contains("\t") ? quoted(value) : value
    }

    private func guardValue(_ value: String, option: String) throws {
        if value.contains("\n") {
            throw SSHConfigError.invalidValue(option: option, reason: "contains newline")
        }
        if value.contains("\0") {
            throw SSHConfigError.invalidValue(option: option, reason: "contains NUL")
        }
    }

    private func guardRawOverride(_ raw: String) throws {
        // Raw is the escape hatch; we still refuse a few things that
        // would break our managed file's invariants.
        if raw.contains("\0") {
            throw SSHConfigError.invalidValue(option: "rawConfigOverride", reason: "contains NUL")
        }
        // We never want a managed entry to introduce a nested Include
        // directive — keeps the surface trivial and avoids cycles.
        let lowered = raw.lowercased()
        for line in lowered.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("include ") || trimmed == "include" {
                throw SSHConfigError.invalidValue(
                    option: "rawConfigOverride",
                    reason: "must not contain Include directive"
                )
            }
            if trimmed.hasPrefix("host ") || trimmed == "host" {
                throw SSHConfigError.invalidValue(
                    option: "rawConfigOverride",
                    reason: "must not start a new Host stanza"
                )
            }
            if trimmed.hasPrefix("match ") || trimmed == "match" {
                throw SSHConfigError.invalidValue(
                    option: "rawConfigOverride",
                    reason: "must not contain Match block"
                )
            }
            // ControlMaster / ControlPath / ControlPersist must NOT be
            // expressed via raw — OpenSSH is first-match-wins, and
            // because our writer emits its own lines first, a raw value
            // here is silently a no-op (UX trap). Tell the user to use
            // the Basic-tab picker instead.
            for forbidden in ["controlmaster ", "controlpath ", "controlpersist "] {
                if trimmed.hasPrefix(forbidden) || trimmed == String(forbidden.dropLast()) {
                    throw SSHConfigError.invalidValue(
                        option: "rawConfigOverride",
                        reason: "set ControlMaster / ControlPath / ControlPersist via the Basic tab — Bastion owns these to manage the master lifecycle"
                    )
                }
            }
        }
    }

    private func quoted(_ value: String) -> String {
        // ssh_config(5) accepts double-quoted values with backslash escapes.
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    /// Expand a leading `~` to the user's home (we own this file; making
    /// the path absolute avoids surprises in unusual `HOME` contexts).
    /// Tokens like `%h` / `%p` / `%r` are passed through untouched.
    private func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return NSString(string: path).expandingTildeInPath
        }
        if path == "~" {
            return NSString(string: path).expandingTildeInPath
        }
        return path
    }
}
