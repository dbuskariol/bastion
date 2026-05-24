import Foundation

public enum BastionIdentifiers {
    public static let bundleID = "com.bastion.app"

    /// Account / login keychain service used for SSH key passphrases. Kept
    /// constant across versions so previous passphrases remain reachable
    /// after upgrades.
    public static let keychainService = "Bastion SSH passphrase"

    /// Where `make install` symlinks the CLI by default. Per the rubber-duck
    /// pass: a symlink (not a copy) preserves a valid binding when Sparkle
    /// atomically swaps the .app bundle on update.
    public static let cliSymlinkPath = "/usr/local/bin/bastion"

    /// Detect Gatekeeper Path Randomization. A translocated bundle path
    /// makes any persisted file references (LaunchAgents, symlinks) point
    /// at an ephemeral mount that disappears the moment the user moves the
    /// app — so we refuse to perform first-run setup from this state.
    public static var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }
}
