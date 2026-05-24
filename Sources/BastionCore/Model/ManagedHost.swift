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

    /// True for hosts whose server demands an interactive FIDO/WebAuthn
    /// challenge that `BatchMode=yes` cannot satisfy (e.g. GitHub's
    /// `vault`). When set, `Connect` runs `ssh -fNM <alias>` in
    /// the user's terminal so they can complete the browser+touch
    /// dance ONCE, then polls `ssh -O check` and auto-opens a shell tab
    /// when the master comes up. Subsequent connects in the same
    /// ControlPersist window are instant.
    public var requiresInteractiveAuth: Bool

    public init(
        id: UUID = UUID(),
        alias: String,
        hostname: String,
        user: String? = nil,
        port: Int = 22,
        identityFiles: [String] = [],
        controlMaster: ControlMasterChoice = .on,
        controlPersist: ControlPersistChoice = .inherit,
        advanced: [SSHOption: String] = [:],
        rawConfigOverride: String? = nil,
        tags: [String] = [],
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        requiresInteractiveAuth: Bool = false
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
        self.requiresInteractiveAuth = requiresInteractiveAuth
    }

    // Custom decoder so adding `requiresInteractiveAuth` doesn't break
    // hosts.json files written before the field existed (default = false).
    private enum CodingKeys: String, CodingKey {
        case id, alias, hostname, user, port, identityFiles
        case controlMaster, controlPersist, advanced, rawConfigOverride
        case tags, notes, createdAt, updatedAt, requiresInteractiveAuth
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.alias = try c.decode(String.self, forKey: .alias)
        self.hostname = try c.decode(String.self, forKey: .hostname)
        self.user = try c.decodeIfPresent(String.self, forKey: .user)
        self.port = try c.decode(Int.self, forKey: .port)
        self.identityFiles = try c.decode([String].self, forKey: .identityFiles)
        self.controlMaster = try c.decode(ControlMasterChoice.self, forKey: .controlMaster)
        self.controlPersist = try c.decode(ControlPersistChoice.self, forKey: .controlPersist)
        self.advanced = try c.decode([SSHOption: String].self, forKey: .advanced)
        self.rawConfigOverride = try c.decodeIfPresent(String.self, forKey: .rawConfigOverride)
        self.tags = try c.decode([String].self, forKey: .tags)
        self.notes = try c.decode(String.self, forKey: .notes)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.requiresInteractiveAuth = try c.decodeIfPresent(Bool.self, forKey: .requiresInteractiveAuth) ?? false
    }

    /// Model-layer save invariants. Called from `ConnectionEngine.upsertHost`
    /// so both the editor and the CLI hit the same enforcement.
    ///
    /// Two rules so far, both load-bearing for the FIDO/SSO bootstrap flow:
    ///
    /// 1. FIDO hosts MUST have `controlMaster == .on`. A FIDO host with
    ///    `.off` is silently broken (we write `ControlMaster no` so the
    ///    `ssh -fNM` we launch can't bind a socket, and `ssh -O check`
    ///    will never find a master). A FIDO host with `.inherit` is only
    ///    valid if the user's global `~/.ssh/config` has `Host *` or a
    ///    matching block that sets ControlMaster — but we have no way to
    ///    verify that here in the model layer. The editor's save-time
    ///    `ssh -G` probe handles the `.inherit` case with a richer
    ///    error. From the CLI we apply the stricter rule (`.on` only).
    /// 2. The resolved ControlPath length must fit Darwin's Unix-socket
    ///    cap (104 chars). Our managed path expands `%C` to a 40-char
    ///    SHA1 hash; we conservatively cap the prefix.
    public func validateForSave() throws {
        if requiresInteractiveAuth && controlMaster == .off {
            throw SSHConfigError.invalidValue(
                option: "controlMaster",
                reason: "FIDO/SSO hosts require ControlMaster=On — otherwise every command would prompt for a FIDO touch. Change ControlMaster to On in the editor."
            )
        }
        // ~/.ssh/sockets/<40-hex-hash> = roughly 60 chars on a typical
        // /Users/<short>/ install. Long-username corporate accounts
        // (/Users/firstname.middlename.lastname/) clip 90+. The Darwin
        // cap is 104. Reject paths likely to exceed it at save time
        // rather than at bind time with an opaque error.
        let homeLen = FileManager.default.homeDirectoryForCurrentUser.path.count
        let socketPrefix = homeLen + "/.ssh/sockets/".count
        let estimatedPathLen = socketPrefix + 40
        if controlMaster == .on && estimatedPathLen > 100 {
            throw SSHConfigError.invalidValue(
                option: "controlPath",
                reason: "Your home directory path is too long for Bastion's default ControlPath (would exceed the 104-character Unix socket limit). Workaround: set a shorter ControlPath in the Raw tab, e.g. `ControlPath /tmp/sshmux/%C`, after manually creating /tmp/sshmux."
            )
        }
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
