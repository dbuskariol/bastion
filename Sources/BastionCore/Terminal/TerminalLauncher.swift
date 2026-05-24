import Foundation

/// Common interface for launching a remote command in a terminal
/// emulator. All launchers funnel through here so the Coordinator
/// doesn't have to branch on terminal identity at the call site.
public protocol TerminalLauncher: Sendable {
    var id: TerminalID { get }

    /// Launch the given command (as argv) in a new tab (default) or
    /// new window. Implementations must use AppleScriptEscape /
    /// URLEncode for any argument that interpolates into a non-argv
    /// transport.
    func launch(argv: [String], newWindow: Bool, environment: [String: String]) throws

    /// For tests: returns what the launcher would invoke instead of
    /// actually spawning. Default = nil (live impl).
    var recorder: TerminalLaunchRecorder? { get }
}

/// Test recorder for argv assertions. Concrete launchers consult this
/// before running a Process; when non-nil, they record + return success
/// without spawning anything.
public final class TerminalLaunchRecorder: @unchecked Sendable {
    public struct Invocation: Sendable, Equatable {
        public var executable: String
        public var arguments: [String]
        public var newWindow: Bool
    }
    private let lock = NSLock()
    private var _invocations: [Invocation] = []
    public init() {}

    public func record(executable: String, arguments: [String], newWindow: Bool) {
        lock.lock(); defer { lock.unlock() }
        _invocations.append(Invocation(executable: executable, arguments: arguments, newWindow: newWindow))
    }

    public var invocations: [Invocation] {
        lock.lock(); defer { lock.unlock() }
        return _invocations
    }
}

/// Errors a launcher may raise.
public enum TerminalLaunchError: Error, CustomStringConvertible, Equatable {
    case notInstalled(TerminalID)
    case automationDenied(TerminalID)
    case unsupportedOperation(TerminalID, reason: String)
    case spawnFailed(String)

    public var description: String {
        switch self {
        case .notInstalled(let id):         return "\(id.displayName) is not installed"
        case .automationDenied(let id):     return "\(id.displayName) refused Apple events (Automation permission denied)"
        case .unsupportedOperation(let id, let r): return "\(id.displayName): \(r)"
        case .spawnFailed(let s):           return "Failed to launch: \(s)"
        }
    }
}

// MARK: - Argv → shell-string helper

/// Build a single safely-quoted shell string from an argv. Used for
/// AppleScript / URL-scheme transports that can't take argv arrays.
public enum ArgvShell {
    /// POSIX-style: single-quote-wrap each arg, double single-quotes via
    /// `'\''`. Result is safe to embed in `sh -c`.
    public static func quote(_ argv: [String]) -> String {
        argv.map { arg in
            "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
