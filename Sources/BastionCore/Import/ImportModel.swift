import Foundation

/// Where an imported connection candidate was found. The UI uses this
/// for the source-pill filters and badges ("seen in zsh × 42, ssh
/// config", etc).
public enum HistorySource: Hashable, Sendable {
    case zshHistory(lineNumber: Int)
    case bashHistory(lineNumber: Int)
    case fishHistory(lineNumber: Int)
    case knownHosts(lineNumber: Int)
    case sshConfig                          // from existing ~/.ssh/config (external)

    public var kind: Kind {
        switch self {
        case .zshHistory:   return .zsh
        case .bashHistory:  return .bash
        case .fishHistory:  return .fish
        case .knownHosts:   return .knownHosts
        case .sshConfig:    return .sshConfig
        }
    }

    public enum Kind: String, Sendable, CaseIterable, Codable {
        case zsh, bash, fish, knownHosts, sshConfig
        public var displayName: String {
            switch self {
            case .zsh:       return ".zsh_history"
            case .bash:      return ".bash_history"
            case .fish:      return "fish history"
            case .knownHosts: return "known_hosts"
            case .sshConfig: return "~/.ssh/config"
            }
        }
    }
}

/// A single SSH connection parsed out of a shell-history line, scp/rsync
/// command, git URL, or ssh:// URI. Multiple parsed connections that
/// share `(lowercased(hostname), port, user)` collapse into a single
/// `ImportCandidate` for display.
public struct ParsedConnection: Hashable, Sendable {
    public var user: String?
    public var hostname: String
    public var port: Int       // resolved, default 22
    public var identityFile: String?
    public var proxyJump: String?
    public var source: HistorySource
    public var timestamp: Date?

    public init(
        user: String? = nil,
        hostname: String,
        port: Int = 22,
        identityFile: String? = nil,
        proxyJump: String? = nil,
        source: HistorySource,
        timestamp: Date? = nil
    ) {
        self.user = user
        self.hostname = hostname
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.source = source
        self.timestamp = timestamp
    }

    /// Dedup key: case-insensitive hostname + port + (user ?? "").
    public struct DedupKey: Hashable, Sendable, Codable {
        public let hostnameLower: String
        public let port: Int
        public let user: String
        public init(_ parsed: ParsedConnection) {
            self.hostnameLower = parsed.hostname.lowercased()
            self.port = parsed.port
            self.user = parsed.user ?? ""
        }
    }
}

/// A deduped + aggregated import candidate, ready to be presented in the
/// review UI. Counts and source-set drive the "seen in zsh × 42 …"
/// display strings.
public struct ImportCandidate: Hashable, Sendable, Identifiable, Codable {
    public let id: ParsedConnection.DedupKey
    public var suggestedAlias: String       // editable in review UI
    public var hostname: String
    public var user: String?
    public var port: Int
    public var identityFiles: [String]      // deduped
    public var proxyJumps: [String]         // deduped
    public var sources: Set<HistorySource.Kind>
    public var firstSeen: Date?
    public var lastSeen: Date?
    public var invocationCount: Int

    public var alreadyManaged: Bool         // set after we compare to HostRegistry

    public init(id: ParsedConnection.DedupKey,
                suggestedAlias: String,
                hostname: String,
                user: String?,
                port: Int,
                identityFiles: [String] = [],
                proxyJumps: [String] = [],
                sources: Set<HistorySource.Kind> = [],
                firstSeen: Date? = nil,
                lastSeen: Date? = nil,
                invocationCount: Int = 0,
                alreadyManaged: Bool = false) {
        self.id = id
        self.suggestedAlias = suggestedAlias
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFiles = identityFiles
        self.proxyJumps = proxyJumps
        self.sources = sources
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.invocationCount = invocationCount
        self.alreadyManaged = alreadyManaged
    }
}

/// Sort modes for ImportEngine.discover output.
public enum ImportSortMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Most recently used first. Default — matches the consensus brief
    /// (lastSeen desc; falls back to invocationCount desc for ties).
    case recent
    /// Most-frequently-invoked first (invocationCount desc; ties broken
    /// by lastSeen desc then alias asc).
    case mostUsed
    /// Alphabetical by suggested alias (case-insensitive).
    case alphabetical

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .recent:       return "Most recent"
        case .mostUsed:     return "Most used"
        case .alphabetical: return "Alphabetical"
        }
    }
}
