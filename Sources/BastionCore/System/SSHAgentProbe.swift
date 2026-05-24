import Foundation

/// Categorises what's plugged into `SSH_AUTH_SOCK`. We use this to avoid
/// calling `ssh-add` against agents that don't accept added keys
/// (1Password's SSH agent is the most common — rubber-duck N1).
public enum SSHAgentKind: String, Codable, Sendable, Equatable {
    /// Apple's own ssh-agent that ships with macOS, reachable via launchd.
    case appleLaunchd
    /// 1Password SSH agent — does NOT accept added keys; we must skip
    /// `ssh-add --apple-use-keychain` for users on this agent.
    case onePassword
    /// Secretive (`https://github.com/maxgoedjen/secretive`) — also
    /// doesn't accept added keys; same skip.
    case secretive
    /// Anything else / unknown — treat like a stock agent.
    case other
    /// `SSH_AUTH_SOCK` not set or not reachable.
    case unavailable
}

/// Resolves the current SSH agent context.
public struct SSHAgentProbe: Sendable {
    public let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func detect() -> SSHAgentKind {
        guard let raw = environment["SSH_AUTH_SOCK"], !raw.isEmpty else {
            return .unavailable
        }
        let socketPath = NSString(string: raw).expandingTildeInPath
        // Apple's launchd socket pattern.
        if socketPath.contains("/com.apple.launchd.")
            && socketPath.contains("/Listeners") {
            return .appleLaunchd
        }
        // 1Password's typical socket paths.
        let onePassPatterns = [
            "/1password/agent.sock",
            "/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock",
            "/1Password/agent.sock",
            "/.1password/agent.sock"
        ]
        for pat in onePassPatterns where socketPath.contains(pat) {
            return .onePassword
        }
        // Secretive's typical socket path.
        if socketPath.lowercased().contains("/secretive/") {
            return .secretive
        }
        return .other
    }

    /// True iff calling `ssh-add` against this agent is safe (i.e. the
    /// agent accepts added keys).
    public var canAddKeys: Bool {
        let kind = detect()
        switch kind {
        case .appleLaunchd, .other: return true
        case .onePassword, .secretive, .unavailable: return false
        }
    }
}
