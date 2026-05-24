import Foundation
import BastionIdentifiers

/// Scans `~/.ssh/` for plausible SSH private-key files so the host editor
/// can offer them as a quick-pick popover instead of forcing the user to
/// type the path. We're conservative: a file counts as a key only if
/// (a) it lives directly under `~/.ssh/`, (b) it doesn't end in `.pub` /
/// `.cert` / `.crt`, (c) it isn't an OpenSSH well-known file
/// (config, known_hosts, authorized_keys, environment), and (d) it's
/// readable mode 0600 (OpenSSH refuses looser perms anyway).
public struct SSHKeyDiscovery {
    public let directory: URL
    private let fileManager: FileManager

    public init(directory: URL = Paths.userSSHDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public struct Candidate: Sendable, Hashable, Identifiable {
        public let path: String
        public var id: String { path }
        public var basename: String {
            (path as NSString).lastPathComponent
        }
        /// True if a sibling `.pub` file exists — implies an actual SSH
        /// keypair, not just a stray file.
        public var hasPublicKey: Bool
        /// True if a sibling `-cert.pub` file exists.
        public var hasCertificate: Bool
    }

    /// Returns key-file candidates sorted by basename (case-insensitive).
    public func discover() -> [Candidate] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let knownNonKeys: Set<String> = [
            "config", "known_hosts", "known_hosts2", "authorized_keys",
            "authorized_keys2", "environment", "sshd_config",
            "rc", "ssh_host_key", "ssh_host_key.pub"
        ]
        var results: [Candidate] = []
        for url in entries {
            let basename = url.lastPathComponent
            if basename.hasPrefix(".") { continue }
            if basename.hasSuffix(".pub") || basename.hasSuffix(".cert") || basename.hasSuffix(".crt") { continue }
            if knownNonKeys.contains(basename) { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let pubSibling = directory.appendingPathComponent("\(basename).pub")
            let certSibling = directory.appendingPathComponent("\(basename)-cert.pub")
            results.append(Candidate(
                path: url.path,
                hasPublicKey: fileManager.fileExists(atPath: pubSibling.path),
                hasCertificate: fileManager.fileExists(atPath: certSibling.path)
            ))
        }
        return results.sorted { $0.basename.lowercased() < $1.basename.lowercased() }
    }
}
