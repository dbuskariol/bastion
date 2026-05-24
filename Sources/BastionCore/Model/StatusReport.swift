import Foundation

/// Live state of the SSH ControlMaster for a single host.
public struct ControlMasterState: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        /// Master is alive — `ssh -O check` succeeded.
        case running
        /// Configured but socket missing — we should establish if asked.
        case down
        /// Socket file exists but `ssh -O check` failed (process died,
        /// socket leaked). The "Reconnect" affordance offers to clean
        /// the stale socket and re-establish.
        case stale
        /// User disabled ControlMaster for this host (or `ssh -G`
        /// reports `controlpath none` / missing — rubber-duck B5).
        case disabled
        /// Bastion couldn't probe (e.g. /usr/bin/ssh missing or stuck).
        case unknown
    }

    public var enabled: Bool
    public var status: Status
    /// Resolved ControlPath as reported by `ssh -G`. May contain unexpanded
    /// `%C` etc when there's no live connection; for live status we use
    /// the post-resolution form.
    public var controlPath: String?
    /// Best-effort pid parsed from `ssh -O check`'s success output.
    public var pid: Int?
    /// First time we *observed* the master come up (FSEvent + check
    /// success). Persisted across menu app restarts so the master's age
    /// survives our restart.
    public var establishedAt: Date?
    /// Process count using this control socket (master + children) minus
    /// the master itself = "attached sessions". Best-effort via `ps`.
    public var attachedSessions: Int?
    /// Resolved ControlPersist in seconds (0 = "yes" indefinite or "no").
    public var persistSeconds: Int?
    /// Last time we ran `ssh -O check` against this host.
    public var lastCheckedAt: Date?

    public init(
        enabled: Bool = false,
        status: Status = .disabled,
        controlPath: String? = nil,
        pid: Int? = nil,
        establishedAt: Date? = nil,
        attachedSessions: Int? = nil,
        persistSeconds: Int? = nil,
        lastCheckedAt: Date? = nil
    ) {
        self.enabled = enabled
        self.status = status
        self.controlPath = controlPath
        self.pid = pid
        self.establishedAt = establishedAt
        self.attachedSessions = attachedSessions
        self.persistSeconds = persistSeconds
        self.lastCheckedAt = lastCheckedAt
    }
}

/// Last error (if any) from a connection attempt for a host.
public struct ConnectionLastError: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var exitCode: Int32
    public var stderrTail: String

    public init(timestamp: Date, exitCode: Int32, stderrTail: String) {
        self.timestamp = timestamp
        self.exitCode = exitCode
        self.stderrTail = stderrTail
    }
}

/// Per-host snapshot for the status JSON the menu app polls.
public struct HostSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var alias: String
    public var hostname: String
    public var resolvedHostname: String?
    public var user: String?
    public var port: Int
    public var identityFiles: [String]
    public var source: HostSource
    public var controlMaster: ControlMasterState
    public var lastError: ConnectionLastError?
    /// Stable lifetime of the master — establishedAt-derived, formatted
    /// for the live diagnostics card.
    public var uptimeSeconds: Int?

    public init(
        id: UUID,
        alias: String,
        hostname: String,
        resolvedHostname: String? = nil,
        user: String? = nil,
        port: Int,
        identityFiles: [String] = [],
        source: HostSource = .managed,
        controlMaster: ControlMasterState = ControlMasterState(),
        lastError: ConnectionLastError? = nil,
        uptimeSeconds: Int? = nil
    ) {
        self.id = id
        self.alias = alias
        self.hostname = hostname
        self.resolvedHostname = resolvedHostname
        self.user = user
        self.port = port
        self.identityFiles = identityFiles
        self.source = source
        self.controlMaster = controlMaster
        self.lastError = lastError
        self.uptimeSeconds = uptimeSeconds
    }
}

/// Identifier for the supported terminal emulators.
public enum TerminalID: String, Codable, Sendable, CaseIterable {
    case terminal     // Terminal.app (Apple, ships with macOS)
    case iterm2
    case ghostty
    case warp
    case alacritty
    case kitty
    case wezterm
    case hyper
    case tabby
    case rio

    public var displayName: String {
        switch self {
        case .terminal:  return "Terminal.app"
        case .iterm2:    return "iTerm2"
        case .ghostty:   return "Ghostty"
        case .warp:      return "Warp"
        case .alacritty: return "Alacritty"
        case .kitty:     return "kitty"
        case .wezterm:   return "WezTerm"
        case .hyper:     return "Hyper"
        case .tabby:     return "Tabby"
        case .rio:       return "Rio"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .terminal:  return "com.apple.Terminal"
        case .iterm2:    return "com.googlecode.iterm2"
        case .ghostty:   return "com.mitchellh.ghostty"
        case .warp:      return "dev.warp.Warp-Stable"
        case .alacritty: return "org.alacritty"
        case .kitty:     return "net.kovidgoyal.kitty"
        case .wezterm:   return "com.github.wez.wezterm"
        case .hyper:     return "co.zeit.hyper"
        case .tabby:     return "org.tabby"
        case .rio:       return "com.raphaelamorim.rio"
        }
    }
}

/// Snapshot of an installed terminal's discovery state. Returned to the UI
/// for the picker; computed by TerminalDetector (commit 7).
public struct TerminalSnapshot: Codable, Sendable, Equatable {
    public let id: TerminalID
    public var installed: Bool
    public var appPath: String?
    public var cliPath: String?
    public var version: String?

    public init(id: TerminalID, installed: Bool = false, appPath: String? = nil, cliPath: String? = nil, version: String? = nil) {
        self.id = id
        self.installed = installed
        self.appPath = appPath
        self.cliPath = cliPath
        self.version = version
    }
}

/// Aggregate status the menu app refreshes from `bastion status --json`.
public struct StatusReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public var generatedAt: Date
    public var appVersion: String
    public var sshBinaryVersion: String?
    public var agentReachable: Bool
    public var oneOnePasswordAgentDetected: Bool
    public var defaultTerminal: TerminalID?
    public var includeInstalled: Bool
    public var hosts: [HostSnapshot]
    public var terminals: [TerminalSnapshot]
    public var iCloudSyncSuspected: Bool

    public static let currentSchemaVersion = 1

    public init(
        appVersion: String,
        sshBinaryVersion: String? = nil,
        agentReachable: Bool = false,
        oneOnePasswordAgentDetected: Bool = false,
        defaultTerminal: TerminalID? = nil,
        includeInstalled: Bool = false,
        hosts: [HostSnapshot] = [],
        terminals: [TerminalSnapshot] = [],
        iCloudSyncSuspected: Bool = false,
        generatedAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.sshBinaryVersion = sshBinaryVersion
        self.agentReachable = agentReachable
        self.oneOnePasswordAgentDetected = oneOnePasswordAgentDetected
        self.defaultTerminal = defaultTerminal
        self.includeInstalled = includeInstalled
        self.hosts = hosts
        self.terminals = terminals
        self.iCloudSyncSuspected = iCloudSyncSuspected
    }
}

/// Pretty-print + parse helpers for `bastion status --json`.
public enum StatusReportJSON {
    public static func encode(_ report: StatusReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(data: try encoder.encode(report), encoding: .utf8) ?? ""
    }

    public static func decode(_ data: Data) throws -> StatusReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StatusReport.self, from: data)
    }
}
