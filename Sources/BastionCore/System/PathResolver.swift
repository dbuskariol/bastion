import Foundation

/// Captures and caches the interactive-shell PATH so child processes
/// Bastion spawns (ssh-add, ssh-keygen, mosh, terminal CLIs) can find
/// Homebrew / Nix / Cargo binaries that launchd-started menu apps would
/// otherwise miss.
///
/// Rubber-duck B2: an `LSUIElement` app launched by Finder/launchd inherits
/// `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. That finds Apple's stock `ssh`,
/// `ssh-add`, `ssh-keygen` but nothing under `/opt/homebrew/bin`,
/// `/usr/local/bin` (Intel Homebrew), `~/.cargo/bin`, `~/.local/bin`,
/// `/etc/profiles/per-user/<u>/bin` (Nix).
///
/// We capture by running the user's login shell once with `-lic 'printf
/// %s "$PATH"'` and cache the result. 2-second timeout; on failure, fall
/// back to a curated default that covers the common cases.
public final class PathResolver: @unchecked Sendable {

    /// Curated fallback PATH used when shell discovery fails.
    public static let fallbackPATH: String = [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin"
    ].joined(separator: ":")

    private let lock = NSLock()
    private var cached: String?

    public init(preloaded: String? = nil) {
        self.cached = preloaded
    }

    /// Returns the resolved PATH, capturing it on first call.
    public func path() -> String {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let resolved = Self.captureInteractiveShellPATH() ?? Self.fallbackPATH
        // Always union the fallback so even shells that strip Homebrew
        // still get a useful PATH.
        cached = Self.union(resolved, Self.fallbackPATH)
        return cached!
    }

    /// Build a process environment with PATH injected. Use this every
    /// time we spawn a Process for ssh / ssh-add / terminal launchers.
    public func environment(adding extras: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path()
        for (k, v) in extras { env[k] = v }
        return env
    }

    // MARK: - Discovery

    private static func captureInteractiveShellPATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        // -l: login shell (sources /etc/profile, ~/.zprofile, …)
        // -i: interactive (sources ~/.zshrc, ~/.bashrc) so users that
        //      add /opt/homebrew/bin in their interactive RC files have it.
        // -c "printf %s $PATH": no trailing newline so we get exactly PATH.
        proc.arguments = ["-lic", "printf %s \"$PATH\""]
        // Minimal env so the shell doesn't loop forever trying to read
        // history from a network mount or similar.
        proc.environment = ["HOME": NSHomeDirectory(), "TERM": "dumb"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return nil
        }
        // 2-second timeout — if the shell hangs we don't want to hold up
        // app launch. Poll waitUntilExit on a background queue.
        let deadline = Date().addingTimeInterval(2.0)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            return nil
        }
        let data = outPipe.fileHandleForReading.availableData
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Combine two PATH strings, preserving order and removing duplicates.
    public static func union(_ a: String, _ b: String) -> String {
        var seen = Set<String>()
        var result: [String] = []
        for piece in (a.split(separator: ":") + b.split(separator: ":")) {
            let s = String(piece)
            guard !s.isEmpty, !seen.contains(s) else { continue }
            seen.insert(s)
            result.append(s)
        }
        return result.joined(separator: ":")
    }
}

/// Tiny `which` helper that respects our resolved PATH. Used by Terminal
/// detection and by the engine to find ssh-add / ssh-keygen / mosh etc.
public struct WhichResolver {
    public let pathResolver: PathResolver
    public init(pathResolver: PathResolver) {
        self.pathResolver = pathResolver
    }

    public func which(_ binary: String) -> URL? {
        let env = pathResolver.environment()
        guard let path = env["PATH"] else { return nil }
        for piece in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(piece)).appendingPathComponent(binary)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
