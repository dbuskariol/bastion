import Foundation

/// Result of running a subprocess to completion (or timing out).
public struct ProcessRunResult: Sendable {
    public let exitCode: Int32?      // nil if killed by timeout
    public let timedOut: Bool
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32?, timedOut: Bool, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Run a subprocess with a hard wall-clock timeout that actually kills
/// the spawned process tree.
///
/// **Why this exists**: Swift's `Task.cancel()` is cooperative. A naive
/// `withTimeout` around an awaiter that wraps `Process.waitUntilExit()`
/// will unblock the await on cancellation but leave the process running.
/// In Bastion's FIDO bootstrap path that means a BatchMode probe that
/// authenticates 100ms after the timeout still creates a master, which
/// then races the foreground `ssh -fNM` we already launched for the
/// same socket. Result: failed FIDO touch, orphaned master, broken UX.
/// Rubber-duck pass on the dual-model consensus surfaced this as the
/// #1 blocking issue.
///
/// Sequence on timeout:
///   1. `Process.terminate()` (SIGTERM)
///   2. wait `gracePeriod` for clean exit
///   3. `kill(-pid, SIGKILL)` for the whole process group if still alive
///   4. `waitUntilExit()` so we don't return until the process is gone
///
/// Returns `ProcessRunResult.timedOut == true` with whatever output was
/// captured before kill. Caller treats that as failure semantically
/// equivalent to a non-zero exit.
public enum ProcessTimeout {

    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        gracePeriod: TimeInterval = 0.2
    ) async -> ProcessRunResult {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        if let environment {
            proc.environment = environment
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return ProcessRunResult(
                exitCode: -1,
                timedOut: false,
                stdout: "",
                stderr: "Failed to spawn \(executable.lastPathComponent): \(error.localizedDescription)"
            )
        }

        return await withTaskGroup(of: TimedRunOutcome.self) { group in
            // Branch 1: process exit + output capture.
            group.addTask {
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                return .completed(
                    exit: proc.terminationStatus,
                    stdout: outData,
                    stderr: errData
                )
            }
            // Branch 2: wall-clock timeout.
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timedOut
            }

            guard let first = await group.next() else {
                return ProcessRunResult(exitCode: -1, timedOut: false, stdout: "", stderr: "lost task group race")
            }

            switch first {
            case .completed(let exit, let outData, let errData):
                group.cancelAll()
                return ProcessRunResult(
                    exitCode: exit,
                    timedOut: false,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                )
            case .timedOut:
                // Two-stage termination: SIGTERM first, wait grace,
                // SIGKILL as the failsafe. ssh -fNM honors SIGTERM
                // cleanly; this gives helper processes (askpass,
                // browser handoff) a chance to clean up.
                let pid = proc.processIdentifier
                proc.terminate()
                let graceNs = UInt64(gracePeriod * 1_000_000_000)
                try? await Task.sleep(nanoseconds: graceNs)
                if proc.isRunning {
                    _ = kill(pid, SIGKILL)
                }
                // Drain stdout/stderr we collected so far in the other
                // branch; we still want to give the user the partial
                // output for diagnostics. Wait for the branch to
                // complete its read after the kill takes effect.
                let drained = await group.next()
                group.cancelAll()
                if case .completed(_, let outData, let errData) = drained {
                    return ProcessRunResult(
                        exitCode: nil,
                        timedOut: true,
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? ""
                    )
                }
                return ProcessRunResult(exitCode: nil, timedOut: true, stdout: "", stderr: "")
            }
        }
    }

    private enum TimedRunOutcome {
        case completed(exit: Int32, stdout: Data, stderr: Data)
        case timedOut
    }
}
