import Foundation
import BastionIdentifiers

/// Shared filesystem layout used by both the CLI and the menu app.
///
/// Centralised here so the menu app and CLI can never drift on path
/// computation. Every path is a function of `appSupportDirectory` plus a
/// stable suffix; no string concatenation lives anywhere else in the code
/// base. The directory layout was nailed down in the dual-model-consensus
/// design — see `~/.copilot/workspaces/.../artifacts/consensus.md`.
public enum Paths {
    // MARK: - Application Support
    public static var appSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Bastion", isDirectory: true)
    }

    public static var hostsFile: URL {
        appSupportDirectory.appendingPathComponent("hosts.json")
    }

    public static var hostsPrevFile: URL {
        appSupportDirectory.appendingPathComponent("hosts.json.prev")
    }

    public static var preferencesFile: URL {
        appSupportDirectory.appendingPathComponent("preferences.json")
    }

    public static var keychainIndexFile: URL {
        appSupportDirectory.appendingPathComponent("keychain-index.json")
    }

    public static var statsLogFile: URL {
        appSupportDirectory.appendingPathComponent("stats-events.jsonl")
    }

    public static var statusCacheFile: URL {
        appSupportDirectory.appendingPathComponent("status-cache.json")
    }

    public static var backupsDirectory: URL {
        appSupportDirectory.appendingPathComponent("backups", isDirectory: true)
    }

    public static var onboardingResumeMarker: URL {
        appSupportDirectory.appendingPathComponent("onboarding-resume-step")
    }

    // MARK: - User SSH
    public static var userSSHDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
    }

    public static var userSSHConfig: URL {
        userSSHDirectory.appendingPathComponent("config")
    }

    public static var userSSHConfigDirectory: URL {
        userSSHDirectory.appendingPathComponent("config.d", isDirectory: true)
    }

    public static var managedConfigFile: URL {
        userSSHConfigDirectory.appendingPathComponent("bastion.conf")
    }

    public static var managedConfigPrevFile: URL {
        userSSHConfigDirectory.appendingPathComponent("bastion.conf.prev")
    }

    public static var managedConfigLockFile: URL {
        userSSHConfigDirectory.appendingPathComponent("bastion.conf.lock")
    }

    /// Master control socket directory. We always set `ControlPath` to
    /// `~/.ssh/sockets/%C` (hashed) for our managed hosts.
    public static var sshSocketsDirectory: URL {
        userSSHDirectory.appendingPathComponent("sockets", isDirectory: true)
    }

    /// Stable per-Mac fingerprint that lives inside `~/.ssh/` so it gets
    /// dragged along by any sync tool (iCloud Drive, Resilio) the user has
    /// pointed at their dotfiles. On launch we re-read this and compare
    /// against the current `(host UUID, system hostname)`. A mismatch means
    /// `~/.ssh` is being shared between Macs and the user gets the
    /// non-blocking "concurrent edits may conflict" banner (consensus §15).
    public static var hostFingerprintFile: URL {
        userSSHDirectory.appendingPathComponent(".bastion-host-fingerprint")
    }

    // MARK: - Setup
    /// `# BEGIN BASTION MANAGED` … `# END BASTION MANAGED`. Sentinel-guarded
    /// so we can find and remove our injected `Include` line on uninstall
    /// without scanning anything else.
    public static let includeBlockBegin = "# BEGIN BASTION MANAGED"
    public static let includeBlockEnd = "# END BASTION MANAGED"

    /// The single line we add to `~/.ssh/config`.
    public static let includeDirective = "Include ~/.ssh/config.d/*.conf"

    public static func ensureAppSupportDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: appSupportDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: backupsDirectory,
            withIntermediateDirectories: true
        )
    }
}
