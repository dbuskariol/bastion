import Foundation

/// Parser for the strings `ssh -O check` / `ssh -O exit` print to stderr.
/// Per the rubber-duck pass: be liberal — match on the `Master running`
/// substring, ignore pid-format variance, treat any non-zero exit as
/// "not alive" without trying to interpret the rest.
public enum SSHCheckParser {

    /// Parsed pid out of "Master running (pid=12345)". Returns nil if the
    /// shape doesn't match — caller treats success as authoritative
    /// regardless.
    public static func parseMasterPid(_ stderr: String) -> Int? {
        guard let range = stderr.range(of: "pid=") else { return nil }
        let after = stderr[range.upperBound...]
        let digits = after.prefix(while: { $0.isNumber })
        return Int(digits)
    }

    /// True iff stderr contains the canonical "Master running" string.
    public static func indicatesMasterRunning(_ stderr: String) -> Bool {
        stderr.contains("Master running") || stderr.contains("master running")
    }

    /// True iff the failure mode is "socket missing" specifically — used
    /// to distinguish "down" from "stale".
    public static func indicatesSocketMissing(_ stderr: String) -> Bool {
        stderr.contains("No such file or directory")
            || stderr.contains("connect to control socket")
            || stderr.contains("Control socket connect")
    }
}

/// Best-effort channel-count probe. OpenSSH does not expose a clean
/// channel-count API; we approximate via `ps -A -o pid,command` and count
/// processes whose argv references the master socket path.
public struct ChannelCountProbe: Sendable {
    public let pathResolver: PathResolver
    public init(pathResolver: PathResolver) { self.pathResolver = pathResolver }

    /// Returns (count, pids) excluding the master process itself.
    /// Conservative: returns nil if `ps` fails entirely so the UI can
    /// show "—" rather than an inaccurate zero.
    public func count(socketPath: String, masterPid: Int? = nil) async -> (count: Int, pids: [Int])? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-A", "-o", "pid,command"]
        proc.environment = pathResolver.environment()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let stdout = String(data: data, encoding: .utf8) ?? ""

        var pids: [Int] = []
        for line in stdout.split(separator: "\n").dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Parse leading PID column.
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            let command = String(parts[1])
            if command.contains(socketPath) {
                if let masterPid, pid == masterPid { continue }
                pids.append(pid)
            }
        }
        return (count: pids.count, pids: pids)
    }
}
