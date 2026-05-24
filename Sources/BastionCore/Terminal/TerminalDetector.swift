import Foundation
import AppKit

/// Wraps the runtime detection step for installed terminal emulators.
/// Uses NSWorkspace's `urlsForApplications(withBundleIdentifier:)`
/// (macOS 12+) — supersedes the deprecated LSCopyApplicationURLsForBundleIdentifier
/// noted in rubber-duck S4.
public struct TerminalDetector {
    public let whichResolver: WhichResolver
    public let workspace: NSWorkspace
    /// Optional override map for tests: returns this app path instead of
    /// querying LaunchServices. Useful in CI runners without those apps
    /// installed.
    public let overrideAppPath: [TerminalID: String?]
    public let overrideCLIPath: [TerminalID: String?]

    public init(
        whichResolver: WhichResolver,
        workspace: NSWorkspace = .shared,
        overrideAppPath: [TerminalID: String?] = [:],
        overrideCLIPath: [TerminalID: String?] = [:]
    ) {
        self.whichResolver = whichResolver
        self.workspace = workspace
        self.overrideAppPath = overrideAppPath
        self.overrideCLIPath = overrideCLIPath
    }

    public func snapshot(for id: TerminalID) -> TerminalSnapshot {
        let appPath = resolvedAppPath(id)
        let cliPath = resolvedCLIPath(id)
        let installed = appPath != nil || cliPath != nil
        return TerminalSnapshot(
            id: id,
            installed: installed,
            appPath: appPath,
            cliPath: cliPath,
            version: nil
        )
    }

    public func snapshots() -> [TerminalSnapshot] {
        TerminalID.allCases.map { snapshot(for: $0) }
    }

    /// First-launch default heuristic: prefer terminals with clean -e
    /// command semantics over AppleScript / URL scheme; Terminal.app is
    /// the always-available fallback.
    public func suggestedDefault() -> TerminalID? {
        let order: [TerminalID] = [
            .iterm2, .ghostty, .wezterm, .warp, .kitty,
            .alacritty, .rio, .tabby, .hyper, .terminal
        ]
        for id in order {
            if snapshot(for: id).installed { return id }
        }
        return nil
    }

    // MARK: - Internals

    private func resolvedAppPath(_ id: TerminalID) -> String? {
        if let override = overrideAppPath[id] {
            return override
        }
        let urls = workspace.urlsForApplications(withBundleIdentifier: id.bundleIdentifier)
        return urls.first?.path
    }

    private func resolvedCLIPath(_ id: TerminalID) -> String? {
        if let override = overrideCLIPath[id] {
            return override
        }
        guard let binary = id.cliBinaryName else { return nil }
        return whichResolver.which(binary)?.path
    }
}

private extension TerminalID {
    /// CLI binary name if this terminal ships one we can shell out to
    /// with `-e <command>`. Returns nil for AppleScript-only or
    /// URL-scheme-only terminals.
    var cliBinaryName: String? {
        switch self {
        case .terminal, .iterm2:           return nil        // AppleScript-driven
        case .warp, .hyper, .tabby:        return nil        // URL-scheme driven (CLI exists but is wrappers; not used)
        case .ghostty:                     return "ghostty"
        case .alacritty:                   return "alacritty"
        case .kitty:                       return "kitty"
        case .wezterm:                     return "wezterm"
        case .rio:                         return "rio"
        }
    }
}
