import Foundation

/// Where a host came from — used for UI presentation and to decide
/// whether we own the configuration or merely surface what the user has
/// already defined.
public enum HostSource: String, Codable, Sendable, CaseIterable {
    case managed
    case external
    case imported
}

/// User's per-host preference for OpenSSH ControlMaster. We always set
/// `ControlPath ~/.ssh/sockets/%C` for managed hosts; this enum decides
/// whether to emit `ControlMaster auto` (on), `ControlMaster no` (off),
/// or omit the directive entirely (inherit).
public enum ControlMasterChoice: String, Codable, Sendable, CaseIterable {
    case inherit
    case on
    case off

    public var configValue: String? {
        switch self {
        case .inherit: return nil
        case .on:      return "auto"
        case .off:     return "no"
        }
    }
}

/// How long the master socket lingers after the last channel closes.
public enum ControlPersistChoice: Codable, Sendable, Hashable {
    case inherit
    case minutes(Int)
    case hours(Int)
    case indefinite
    case disabled

    public static let defaultChoice: ControlPersistChoice = .hours(8)

    public static let presets: [ControlPersistChoice] = [
        .minutes(10), .minutes(30), .hours(1), .hours(4),
        .hours(8), .hours(24), .indefinite, .disabled
    ]

    public var displayName: String {
        switch self {
        case .inherit:        return "Inherit"
        case .minutes(let m): return "\(m) min"
        case .hours(let h):   return "\(h) h"
        case .indefinite:     return "Indefinite"
        case .disabled:       return "Disabled"
        }
    }

    public var configValue: String? {
        switch self {
        case .inherit:        return nil
        case .minutes(let m): return "\(m)m"
        case .hours(let h):   return "\(h)h"
        case .indefinite:     return "yes"
        case .disabled:       return "no"
        }
    }
}

/// A single saved SSH host. Stable `id` survives alias renames so
/// external references (UI selection, stats events) don't break.
public struct ManagedHost: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: UUID
    public var alias: String                  // matches Alias.regex
    public var hostname: String
    public var user: String?
    public var port: Int                      // default 22
    public var identityFiles: [String]
    public var controlMaster: ControlMasterChoice
    public var controlPersist: ControlPersistChoice
    public var advanced: [SSHOption: String]
    public var rawConfigOverride: String?
    public var tags: [String]
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        alias: String,
        hostname: String,
        user: String? = nil,
        port: Int = 22,
        identityFiles: [String] = [],
        controlMaster: ControlMasterChoice = .inherit,
        controlPersist: ControlPersistChoice = .inherit,
        advanced: [SSHOption: String] = [:],
        rawConfigOverride: String? = nil,
        tags: [String] = [],
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.alias = alias
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFiles = identityFiles
        self.controlMaster = controlMaster
        self.controlPersist = controlPersist
        self.advanced = advanced
        self.rawConfigOverride = rawConfigOverride
        self.tags = tags
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Strict alias validation. Aliases land in `~/.ssh/config.d/bastion.conf`
/// as `Host <alias>`; OpenSSH parses by whitespace so a space would
/// silently split into multiple hosts. ASCII letters, digits, dot,
/// dash, underscore. Roundtrip-safe.
public enum Alias {
    public static let pattern = "^[A-Za-z0-9._-]+$"

    public static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 256 else { return false }
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
