import Foundation

/// Source descriptor for `ImportEngine.discover`.
public enum ImportSourceID: String, Sendable, CaseIterable {
    case zsh, bash, fish, knownHosts, sshConfig, all
}

/// Wraps every importer (per-shell parsers + extractor chain +
/// known_hosts + existing-ssh-config) and produces a deduplicated
/// candidate list ready for the review UI.
///
/// Privacy contract: nothing read from history files ever leaves this
/// process's memory. The engine produces ImportCandidate values that
/// the caller turns into ManagedHost upserts; once the user dismisses
/// the import flow the history-derived data is freed.
public struct ImportEngine: Sendable {
    public let bash = BashHistoryParser()
    public let zsh = ZshHistoryParser()
    public let fish = FishHistoryParser()
    public let knownHosts = KnownHostsParser()
    public let chain = CommandExtractorChain()
    public let registry: HostRegistry

    public init(registry: HostRegistry) {
        self.registry = registry
    }

    /// Lazily built so we don't have to make UserSSHConfigScanner Sendable
    /// (it holds a FileManager reference which isn't Sendable in stdlib).
    private var scanner: UserSSHConfigScanner { UserSSHConfigScanner() }

    /// Returns deduped, aggregated candidates from the requested sources.
    public func discover(sources: [ImportSourceID]) -> [ImportCandidate] {
        var aggregated: [ParsedConnection.DedupKey: ImportCandidate] = [:]

        let expanded = sources.contains(.all)
            ? Array(ImportSourceID.allCases.filter { $0 != .all })
            : sources

        for source in expanded {
            switch source {
            case .zsh:
                let path = NSHomeDirectory() + "/.zsh_history"
                if let text = readSafe(path) {
                    for (cmd, lineNo, ts) in zsh.extractLines(from: text) {
                        for parsed in chain.extract(line: cmd, source: .zshHistory(lineNumber: lineNo), timestamp: ts) {
                            absorb(parsed, into: &aggregated)
                        }
                    }
                }
            case .bash:
                let path = NSHomeDirectory() + "/.bash_history"
                if let text = readSafe(path) {
                    for (cmd, lineNo, ts) in bash.extractLines(from: text) {
                        for parsed in chain.extract(line: cmd, source: .bashHistory(lineNumber: lineNo), timestamp: ts) {
                            absorb(parsed, into: &aggregated)
                        }
                    }
                }
            case .fish:
                let candidates = [
                    NSHomeDirectory() + "/.local/share/fish/fish_history",
                    NSHomeDirectory() + "/.config/fish/fish_history"
                ]
                for path in candidates {
                    if let text = readSafe(path) {
                        for (cmd, lineNo, ts) in fish.extractLines(from: text) {
                            for parsed in chain.extract(line: cmd, source: .fishHistory(lineNumber: lineNo), timestamp: ts) {
                                absorb(parsed, into: &aggregated)
                            }
                        }
                    }
                }
            case .knownHosts:
                if let text = readSafe(Paths.userSSHDirectory.appendingPathComponent("known_hosts").path) {
                    for parsed in knownHosts.extract(from: text) {
                        absorb(parsed, into: &aggregated)
                    }
                }
            case .sshConfig:
                if let scan = try? scanner.scan() {
                    for alias in scan.existingHostAliases {
                        // External hosts from the user's existing config — we
                        // surface them as ImportCandidates but mark them
                        // already-managed-elsewhere via a synthetic source.
                        // Hostname is whatever ssh -G resolves to — but we
                        // don't run ssh -G per-host here to keep the import
                        // fast. The review UI can resolve on selection.
                        let parsed = ParsedConnection(
                            user: nil, hostname: alias, port: 22,
                            source: .sshConfig
                        )
                        absorb(parsed, into: &aggregated)
                    }
                }
            case .all:
                continue
            }
        }

        // Mark already-managed candidates so the UI can grey them out.
        let registryKeys = Set(registry.hosts.map {
            ParsedConnection.DedupKey(ParsedConnection(
                user: $0.user, hostname: $0.hostname, port: $0.port,
                source: .sshConfig
            ))
        })
        return aggregated.values.map { candidate in
            var c = candidate
            c.alreadyManaged = registryKeys.contains(candidate.id)
            return c
        }.sorted { lhs, rhs in
            // Most-recently-seen first; ties broken by invocation count
            // descending then alias asc.
            let lhsKey = lhs.lastSeen ?? Date.distantPast
            let rhsKey = rhs.lastSeen ?? Date.distantPast
            if lhsKey != rhsKey { return lhsKey > rhsKey }
            if lhs.invocationCount != rhs.invocationCount {
                return lhs.invocationCount > rhs.invocationCount
            }
            return lhs.suggestedAlias < rhs.suggestedAlias
        }
    }

    /// Absorb a ParsedConnection into the aggregated map.
    private func absorb(_ parsed: ParsedConnection,
                        into aggregated: inout [ParsedConnection.DedupKey: ImportCandidate]) {
        let key = ParsedConnection.DedupKey(parsed)
        if var existing = aggregated[key] {
            existing.invocationCount += 1
            if let ts = parsed.timestamp {
                if existing.firstSeen == nil || ts < (existing.firstSeen ?? .distantFuture) {
                    existing.firstSeen = ts
                }
                if existing.lastSeen == nil || ts > (existing.lastSeen ?? .distantPast) {
                    existing.lastSeen = ts
                }
            }
            existing.sources.insert(parsed.source.kind)
            if let id = parsed.identityFile, !existing.identityFiles.contains(id) {
                existing.identityFiles.append(id)
            }
            if let pj = parsed.proxyJump, !existing.proxyJumps.contains(pj) {
                existing.proxyJumps.append(pj)
            }
            aggregated[key] = existing
        } else {
            let alias = Self.suggestAlias(for: parsed)
            var candidate = ImportCandidate(
                id: key,
                suggestedAlias: alias,
                hostname: parsed.hostname,
                user: parsed.user,
                port: parsed.port,
                identityFiles: parsed.identityFile.map { [$0] } ?? [],
                proxyJumps: parsed.proxyJump.map { [$0] } ?? [],
                sources: [parsed.source.kind],
                firstSeen: parsed.timestamp,
                lastSeen: parsed.timestamp,
                invocationCount: 1
            )
            // Adjust alias if conflicts with existing host (suffix -2, -3, …).
            candidate.suggestedAlias = uniqueAlias(candidate.suggestedAlias, existing: aggregated)
            aggregated[key] = candidate
        }
    }

    /// Suggest a short alias from the hostname:
    /// - For IP addresses: replace dots with dashes (so 10.0.5.21 → 10-0-5-21).
    /// - For DNS names: take the first label (stuff before the first dot).
    /// - Fallback to the full hostname with dots replaced.
    static func suggestAlias(for parsed: ParsedConnection) -> String {
        let host = parsed.hostname
        // Detect IPv4: all label-tokens are digits.
        let parts = host.split(separator: ".").map(String.init)
        let isIPv4 = parts.count == 4 && parts.allSatisfy { Int($0) != nil }
        let candidate: String
        if isIPv4 {
            candidate = host.replacingOccurrences(of: ".", with: "-")
        } else if let dot = host.firstIndex(of: ".") {
            candidate = String(host[..<dot])
        } else {
            candidate = host
        }
        // Strip anything our alias regex would reject.
        let cleaned = candidate.filter { c in
            c.isLetter || c.isNumber || c == "-" || c == "_" || c == "."
        }
        return cleaned.isEmpty ? "host" : cleaned
    }

    private func uniqueAlias(_ proposed: String,
                             existing: [ParsedConnection.DedupKey: ImportCandidate]) -> String {
        let used = Set(existing.values.map { $0.suggestedAlias.lowercased() })
            .union(registry.hosts.map { $0.alias.lowercased() })
        if !used.contains(proposed.lowercased()) { return proposed }
        var n = 2
        while used.contains("\(proposed)-\(n)".lowercased()) { n += 1 }
        return "\(proposed)-\(n)"
    }

    private func readSafe(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}
