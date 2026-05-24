import Foundation
import BastionIdentifiers

/// Wraps ssh-keygen to generate ed25519 keys + ssh-add to load them
/// into the agent on demand. All invocations go through PathResolver
/// so users with Homebrew OpenSSH-on-PATH still get Apple's
/// /usr/bin/ssh-add (with --apple-use-keychain support).
public struct KeyGenerator {
    public let pathResolver: PathResolver
    public let keychain: KeychainPassphraseStore
    public let fileManager: FileManager

    public init(
        pathResolver: PathResolver,
        keychain: KeychainPassphraseStore = KeychainPassphraseStore(),
        fileManager: FileManager = .default
    ) {
        self.pathResolver = pathResolver
        self.keychain = keychain
        self.fileManager = fileManager
    }

    public enum KeyGenError: Error, CustomStringConvertible {
        case fileExists(String)
        case sshKeygenFailed(stderr: String)
        case io(String)

        public var description: String {
            switch self {
            case .fileExists(let p):       return "Key already exists at \(p) — pick a different name."
            case .sshKeygenFailed(let s):  return "ssh-keygen failed: \(s)"
            case .io(let s):               return "I/O: \(s)"
            }
        }
    }

    /// Generate an ed25519 keypair at ~/.ssh/<filename>. Stores the
    /// passphrase in Keychain (per-device, never iCloud-synced). Returns
    /// the absolute path of the private key.
    @discardableResult
    public func generateEd25519(
        filename: String,
        comment: String,
        passphrase: String
    ) async throws -> URL {
        let path = Paths.userSSHDirectory.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: path.path) {
            throw KeyGenError.fileExists(path.path)
        }
        try ensureSSHDir()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        proc.arguments = [
            "-t", "ed25519",
            "-f", path.path,
            "-C", comment,
            "-N", passphrase   // empty string = no passphrase
        ]
        proc.environment = pathResolver.environment()

        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw KeyGenError.sshKeygenFailed(stderr: stderr)
        }
        // Store the passphrase if non-empty.
        if !passphrase.isEmpty {
            try keychain.set(passphrase: passphrase, for: path.path)
        }
        return path
    }

    /// Generate a hardware-FIDO ed25519-sk key. The user is prompted to
    /// touch their security key during this call — runs to completion
    /// when they tap. We can't really hide that prompt; the caller
    /// (host editor) shows an explanatory sheet first.
    @discardableResult
    public func generateEd25519SK(filename: String, comment: String) async throws -> URL {
        let path = Paths.userSSHDirectory.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: path.path) {
            throw KeyGenError.fileExists(path.path)
        }
        try ensureSSHDir()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        proc.arguments = [
            "-t", "ed25519-sk",
            "-f", path.path,
            "-C", comment,
            "-N", ""   // FIDO touch is the second factor; no passphrase needed
        ]
        proc.environment = pathResolver.environment()
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw KeyGenError.sshKeygenFailed(stderr: "exit \(proc.terminationStatus)")
        }
        return path
    }

    /// Try to load every Bastion-known key passphrase into the agent.
    /// Rubber-duck N1: skip the call entirely if SSH_AUTH_SOCK points at
    /// a 1Password / Secretive agent (those refuse added keys).
    public func reloadAgent(probe: SSHAgentProbe = SSHAgentProbe()) async {
        guard probe.canAddKeys else { return }
        guard let paths = try? keychain.allKeyPaths() else { return }
        for path in paths {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
            proc.arguments = ["--apple-use-keychain", path]
            proc.environment = pathResolver.environment()
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    private func ensureSSHDir() throws {
        do {
            try fileManager.createDirectory(
                at: Paths.userSSHDirectory,
                withIntermediateDirectories: true,
                attributes: [FileAttributeKey.posixPermissions: 0o700]
            )
        } catch {
            throw KeyGenError.io("mkdir ~/.ssh: \(error.localizedDescription)")
        }
    }
}
