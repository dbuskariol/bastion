import Foundation

/// Local-host filter so we never propose to import `ssh localhost` etc.
private func isLocalHost(_ host: String) -> Bool {
    let lower = host.lowercased()
    return lower == "localhost" || lower == "127.0.0.1" || lower == "::1" || lower == "0.0.0.0"
}

/// Extracts ssh / scp / sftp / mosh / rsync / git / ssh:// invocations
/// from a shell command line.
public struct SshExtractor: CommandExtractor {
    public init() {}
    public func extract(argv: [String], source: HistorySource, timestamp: Date?) -> [ParsedConnection] {
        guard let cmd = argv.first, cmd == "ssh" || cmd.hasSuffix("/ssh") else { return [] }
        var user: String?
        var hostname: String?
        var port: Int = 22
        var identityFile: String?
        var proxyJump: String?

        var i = 1
        let args = Array(argv.dropFirst())
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-p":
                if i + 1 < args.count, let p = Int(args[i + 1]) { port = p; i += 1 }
            case "-l":
                if i + 1 < args.count { user = args[i + 1]; i += 1 }
            case "-i":
                if i + 1 < args.count { identityFile = args[i + 1]; i += 1 }
            case "-J":
                if i + 1 < args.count { proxyJump = args[i + 1]; i += 1 }
            case "-o":
                if i + 1 < args.count {
                    parseDashO(args[i + 1], user: &user, hostname: &hostname, port: &port,
                              identityFile: &identityFile, proxyJump: &proxyJump)
                    i += 1
                }
            case "-F":
                // External config file — we'd have to read it to know what
                // this references. Skip rather than guess.
                return []
            default:
                if arg.hasPrefix("-") {
                    // Unknown short flag; skip its value if it consumes one.
                    if arg.count == 2, "iJlopFb".contains(arg.last!) {
                        i += 1
                    }
                } else if arg.hasPrefix("ssh://") {
                    if let url = parseSSHURL(arg) {
                        return [ParsedConnection(
                            user: url.user, hostname: url.host, port: url.port ?? 22,
                            identityFile: identityFile, proxyJump: proxyJump,
                            source: source, timestamp: timestamp
                        )]
                    }
                } else if hostname == nil {
                    // First non-flag positional is the [user@]host[:port] target.
                    if let parts = HostTokenParser.parse(arg) {
                        if user == nil, let u = parts.user { user = u }
                        hostname = parts.host
                        if let p = parts.port { port = p }
                    }
                }
                // Subsequent positionals are the remote command — we don't care.
            }
            i += 1
        }

        guard let host = hostname, !isLocalHost(host) else { return [] }
        return [ParsedConnection(
            user: user, hostname: host, port: port,
            identityFile: identityFile, proxyJump: proxyJump,
            source: source, timestamp: timestamp
        )]
    }

    private func parseDashO(_ kv: String,
                            user: inout String?,
                            hostname: inout String?,
                            port: inout Int,
                            identityFile: inout String?,
                            proxyJump: inout String?) {
        guard let eq = kv.firstIndex(of: "=") else { return }
        let key = kv[..<eq].lowercased()
        let value = String(kv[kv.index(after: eq)...])
        switch key {
        case "hostname": hostname = value
        case "port":     port = Int(value) ?? port
        case "user":     user = value
        case "identityfile": identityFile = value
        case "proxyjump": proxyJump = value
        default: break
        }
    }

    private struct SSHURL { var user: String?; var host: String; var port: Int? }
    private func parseSSHURL(_ raw: String) -> SSHURL? {
        var s = raw.dropFirst("ssh://".count)
        var user: String?
        if let at = s.firstIndex(of: "@") {
            user = String(s[..<at])
            s = s[s.index(after: at)...]
        }
        if let slash = s.firstIndex(of: "/") { s = s[..<slash] }
        let token = String(s)
        guard let parts = HostTokenParser.parse(token) else { return nil }
        return SSHURL(user: user ?? parts.user, host: parts.host, port: parts.port)
    }
}

/// scp: capital `-P` for port, target token may be either src or dst.
public struct ScpExtractor: CommandExtractor {
    public init() {}
    public func extract(argv: [String], source: HistorySource, timestamp: Date?) -> [ParsedConnection] {
        guard let cmd = argv.first, cmd == "scp" || cmd.hasSuffix("/scp") else { return [] }
        var user: String?
        var port = 22
        var identityFile: String?
        var i = 1
        var connections: [ParsedConnection] = []
        let args = Array(argv.dropFirst())
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-P":
                if i + 1 < args.count, let p = Int(args[i + 1]) { port = p; i += 1 }
            case "-i":
                if i + 1 < args.count { identityFile = args[i + 1]; i += 1 }
            case "-l":
                if i + 1 < args.count { user = args[i + 1]; i += 1 }
            default:
                if arg.hasPrefix("-") {
                    if arg.count == 2, "iPlc".contains(arg.last!) { i += 1 }
                } else if let colon = arg.firstIndex(of: ":") {
                    // user@host:path → grab user@host portion.
                    let target = String(arg[..<colon])
                    if let parts = HostTokenParser.parse(target),
                       !isLocalHost(parts.host) {
                        connections.append(ParsedConnection(
                            user: parts.user ?? user,
                            hostname: parts.host,
                            port: parts.port ?? port,
                            identityFile: identityFile,
                            source: source, timestamp: timestamp
                        ))
                    }
                }
            }
            i += 1
        }
        return connections
    }
}

/// sftp: same flag set as ssh (-P for port? no, -P actually doesn't exist
/// on sftp; sftp uses `-P` too. OpenSSH sftp uses `-P port`).
public struct SftpExtractor: CommandExtractor {
    public init() {}
    public func extract(argv: [String], source: HistorySource, timestamp: Date?) -> [ParsedConnection] {
        guard let cmd = argv.first, cmd == "sftp" || cmd.hasSuffix("/sftp") else { return [] }
        var user: String?, hostname: String?, port = 22
        var i = 1
        let args = Array(argv.dropFirst())
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-P":
                if i + 1 < args.count, let p = Int(args[i + 1]) { port = p; i += 1 }
            case "-l":
                if i + 1 < args.count { user = args[i + 1]; i += 1 }
            default:
                if arg.hasPrefix("-") {
                    if arg.count == 2, "iPlb".contains(arg.last!) { i += 1 }
                } else if hostname == nil {
                    if let parts = HostTokenParser.parse(arg) {
                        if user == nil, let u = parts.user { user = u }
                        hostname = parts.host
                        if let p = parts.port { port = p }
                    }
                }
            }
            i += 1
        }
        guard let host = hostname, !isLocalHost(host) else { return [] }
        return [ParsedConnection(user: user, hostname: host, port: port,
                                 source: source, timestamp: timestamp)]
    }
}

/// mosh: `mosh [--ssh="ssh -p N"] user@host`. Parse the nested ssh args.
public struct MoshExtractor: CommandExtractor {
    public init() {}
    public func extract(argv: [String], source: HistorySource, timestamp: Date?) -> [ParsedConnection] {
        guard let cmd = argv.first, cmd == "mosh" || cmd.hasSuffix("/mosh") else { return [] }
        var port = 22
        var user: String?
        var hostname: String?
        for arg in argv.dropFirst() {
            if arg.hasPrefix("--ssh=") {
                let inner = String(arg.dropFirst("--ssh=".count))
                // crude --ssh="ssh -p 2222" parse
                if let pIndex = inner.range(of: "-p "),
                   let n = Int(inner[pIndex.upperBound...].prefix(while: { $0.isNumber })) {
                    port = n
                }
            } else if !arg.hasPrefix("-") {
                if let parts = HostTokenParser.parse(arg) {
                    user = parts.user
                    hostname = parts.host
                    if let p = parts.port { port = p }
                }
            }
        }
        guard let host = hostname, !isLocalHost(host) else { return [] }
        return [ParsedConnection(user: user, hostname: host, port: port,
                                 source: source, timestamp: timestamp)]
    }
}

/// rsync: `-e "ssh -p N"` is the transport. host:path syntax for src/dst.
public struct RsyncExtractor: CommandExtractor {
    public init() {}
    public func extract(argv: [String], source: HistorySource, timestamp: Date?) -> [ParsedConnection] {
        guard let cmd = argv.first, cmd == "rsync" || cmd.hasSuffix("/rsync") else { return [] }
        var port = 22
        var connections: [ParsedConnection] = []
        var i = 1
        let args = Array(argv.dropFirst())
        while i < args.count {
            let arg = args[i]
            if arg == "-e" || arg == "--rsh" {
                if i + 1 < args.count {
                    let inner = args[i + 1]
                    if let pRange = inner.range(of: "-p ") {
                        let after = inner[pRange.upperBound...]
                        if let n = Int(after.prefix(while: { $0.isNumber })) {
                            port = n
                        }
                    }
                    i += 1
                }
            } else if arg.hasPrefix("--rsh=") {
                let inner = String(arg.dropFirst("--rsh=".count))
                if let pRange = inner.range(of: "-p ") {
                    let after = inner[pRange.upperBound...]
                    if let n = Int(after.prefix(while: { $0.isNumber })) {
                        port = n
                    }
                }
            } else if !arg.hasPrefix("-"), let colon = arg.firstIndex(of: ":") {
                let target = String(arg[..<colon])
                if let parts = HostTokenParser.parse(target),
                   !isLocalHost(parts.host) {
                    connections.append(ParsedConnection(
                        user: parts.user,
                        hostname: parts.host,
                        port: parts.port ?? port,
                        source: source, timestamp: timestamp
                    ))
                }
            }
            i += 1
        }
        return connections
    }
}

/// git clone / fetch / push / pull. Two URL shapes:
///   - SCP-style: user@host:owner/repo.git
///   - ssh://    : ssh://user@host:port/path
public struct GitExtractor: CommandExtractor {
    public init() {}
    public func extract(argv: [String], source: HistorySource, timestamp: Date?) -> [ParsedConnection] {
        guard let cmd = argv.first, cmd == "git" || cmd.hasSuffix("/git") else { return [] }
        // Skip if this isn't a remote-touching subcommand.
        guard argv.count >= 2 else { return [] }
        let sub = argv[1]
        guard ["clone", "fetch", "push", "pull", "remote", "ls-remote"].contains(sub) else {
            return []
        }
        var results: [ParsedConnection] = []
        for arg in argv.dropFirst(2) {
            if arg.hasPrefix("ssh://") {
                let s = arg.dropFirst("ssh://".count)
                var user: String?, hostPort = String(s)
                if let at = s.firstIndex(of: "@") {
                    user = String(s[..<at])
                    hostPort = String(s[s.index(after: at)...])
                }
                if let slash = hostPort.firstIndex(of: "/") {
                    hostPort = String(hostPort[..<slash])
                }
                if let parts = HostTokenParser.parse(hostPort),
                   !isLocalHost(parts.host) {
                    results.append(ParsedConnection(
                        user: user ?? parts.user,
                        hostname: parts.host,
                        port: parts.port ?? 22,
                        source: source, timestamp: timestamp
                    ))
                }
            } else if arg.contains("@"), let colon = arg.firstIndex(of: ":") {
                // SCP-style git URL: user@host:owner/repo.git
                let target = String(arg[..<colon])
                if let parts = HostTokenParser.parse(target),
                   !isLocalHost(parts.host) {
                    results.append(ParsedConnection(
                        user: parts.user, hostname: parts.host,
                        port: 22,
                        source: source, timestamp: timestamp
                    ))
                }
            }
        }
        return results
    }
}

/// Aggregates all extractors. Tries each on each tokenized line; returns
/// the union.
public struct CommandExtractorChain: Sendable {
    public let extractors: [CommandExtractor]
    public init(extractors: [CommandExtractor] = [
        SshExtractor(), ScpExtractor(), SftpExtractor(),
        MoshExtractor(), RsyncExtractor(), GitExtractor()
    ]) {
        self.extractors = extractors
    }
    public func extract(line: String, source: HistorySource, timestamp: Date? = nil,
                        tokenizer: ShellTokenizer = ShellTokenizer()) -> [ParsedConnection] {
        let argv: [String]
        do {
            argv = try tokenizer.tokenize(line)
        } catch {
            return []
        }
        var results: [ParsedConnection] = []
        for extractor in extractors {
            results.append(contentsOf: extractor.extract(argv: argv, source: source, timestamp: timestamp))
        }
        return results
    }
}
