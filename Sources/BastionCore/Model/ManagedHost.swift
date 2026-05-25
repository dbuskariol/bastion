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

    public var displayName: String {
        switch self {
        case .inherit: return "Inherit"
        case .on:      return "On"
        case .off:     return "Off"
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
    /// challenge that `BatchMode=yes` cannot satisfy (typical of
    /// SSO-fronted SSH bastions). When set, `Connect` runs
    /// `ssh -fNM <alias>` in
    /// the user's terminal so they can complete the browser+touch
    /// dance ONCE, then polls `ssh -O check` and auto-opens a shell tab
    /// when the master comes up. Subsequent connects in the same
    /// ControlPersist window are instant.
    public var requiresInteractiveAuth: Bool

    /// Stable, Bastion-owned identifier embedded in the master-socket
    /// path. Default = first 12 hex of `id.uuidString` lowercased. Per
    /// dual-model consensus + rubber-duck N3: 12 hex = 48 bits → for
    /// the 100-host scale Bastion targets, p(collision) ≈ 3×10⁻¹² vs
    /// ~10⁻⁶ at 8 hex. Same path-length budget either way (the runtime
    /// path is `~/.ssh/sockets/bastion-<12hex>-<port>-<user>` ≈ 60+home).
    ///
    /// Decoupled from `host.id` so we can regenerate on corruption /
    /// future shared-mux groups without touching the identity field
    /// (which is referenced by stats events, UI selection, the `# id:`
    /// comment in bastion.conf, and external-reference promises).
    ///
    /// Optional: nil means "derive from id at writer time"; explicit
    /// value wins. Mutated only by future migration tools, never by
    /// the editor.
    public var controlMuxID: String?

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
        requiresInteractiveAuth: Bool = false,
        controlMuxID: String? = nil
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
        self.controlMuxID = controlMuxID
    }

    /// Resolved per-host mux identifier embedded in `~/.ssh/sockets/bastion-<id>-%p-%r`.
    /// Returns the persisted `controlMuxID` if set, otherwise derives from `host.id`.
    /// Always lowercase hex, 12 chars (48 bits). Single source of truth used by the
    /// writer, integration validation, and any UI surface that needs the path prefix.
    public var resolvedControlMuxID: String {
        if let muxID = controlMuxID, !muxID.isEmpty {
            return muxID
        }
        return String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    // Custom decoder so adding `requiresInteractiveAuth` and
    // `controlMuxID` doesn't break hosts.json files written before
    // those fields existed.
    private enum CodingKeys: String, CodingKey {
        case id, alias, hostname, user, port, identityFiles
        case controlMaster, controlPersist, advanced, rawConfigOverride
        case tags, notes, createdAt, updatedAt, requiresInteractiveAuth
        case controlMuxID
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
        self.controlMuxID = try c.decodeIfPresent(String.self, forKey: .controlMuxID)
    }

    /// Model-layer save invariants. Called from `ConnectionEngine.upsertHost`
    /// so both the editor and the CLI hit the same enforcement.
    ///
    /// Rules:
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
    ///    cap (104 chars). Our managed path is
    ///    `~/.ssh/sockets/bastion-<12hex>-<port>-<user>` where `<port>`
    ///    is up to 5 digits and `<user>` is bounded by the POSIX
    ///    `_POSIX_LOGIN_NAME_MAX` of 9 in theory but realistically 32
    ///    on macOS (`sysconf(_SC_LOGIN_NAME_MAX)`).
    /// 3. Hostname must not contain shell-glob metacharacters when
    ///    `controlMaster` is enabled — we emit `Match host <hostname>`
    ///    blocks (per the dual-model + rubber-duck design for shared
    ///    masters across alias/hostname variants), and `Match host`
    ///    pattern-matches its argument. A literal `*.internal` would
    ///    over-match catastrophically. Per rubber-duck S2.
    public func validateForSave() throws {
        if requiresInteractiveAuth && controlMaster == .off {
            throw SSHConfigError.invalidValue(
                option: "controlMaster",
                reason: "FIDO/SSO hosts require ControlMaster=On — otherwise every command would prompt for a FIDO touch. Change ControlMaster to On in the editor."
            )
        }
        if controlMaster != .off,
           hostname.contains(where: { "*?!".contains($0) }) {
            throw SSHConfigError.invalidValue(
                option: "hostname",
                reason: "Hostname must be a literal hostname, not a glob pattern (contains one of `*`, `?`, `!`). Bastion emits a `Match host <hostname>` block to share ControlMaster across typed variants of the same host; a glob there would over-match other hosts."
            )
        }
        // ~/.ssh/sockets/bastion-<12hex>-<port>-<user>:
        //   "bastion-" = 8
        //   12hex      = 12
        //   "-"        = 1
        //   port       = up to 5
        //   "-"        = 1
        //   user       = bounded by POSIX login name max; budget 32
        //   Total      = 8 + 12 + 1 + 5 + 1 + 32 = 59 chars after
        //               "~/.ssh/sockets/" (= 15) → 74 chars after $HOME.
        // The Darwin sun_path cap is 104. Long-username corporate
        // home dirs (/Users/firstname.middlename.lastname/) can clip 90+.
        let homeLen = FileManager.default.homeDirectoryForCurrentUser.path.count
        let socketPrefix = homeLen + "/.ssh/sockets/".count
        let estimatedPathLen = socketPrefix + 59
        if controlMaster == .on && estimatedPathLen > 100 {
            throw SSHConfigError.invalidValue(
                option: "controlPath",
                reason: "Your home directory path is too long for Bastion's default ControlPath (would exceed the 104-character Unix socket limit). Workaround: set a shorter ControlPath in the Raw tab, e.g. `ControlPath /tmp/sshmux/bastion-<id>-%p-%r`, after manually creating /tmp/sshmux."
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
