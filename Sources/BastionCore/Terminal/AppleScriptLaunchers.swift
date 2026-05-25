import Foundation

/// AppleScript-based launcher for Terminal.app. The script is constructed
/// via AppleScriptEscape so any quotes/backslashes in the command are
/// escaped exactly once at a single boundary.
public struct TerminalAppLauncher: TerminalLauncher {
    public let id: TerminalID = .terminal
    public let recorder: TerminalLaunchRecorder?
    public init(recorder: TerminalLaunchRecorder? = nil) { self.recorder = recorder }

    public func launch(argv: [String], newWindow: Bool, environment: [String: String]) throws {
        let shellCommand = ArgvShell.quote(argv)
        let script: String
        if newWindow {
            script = """
            tell application "Terminal"
                activate
                do script \(AppleScriptEscape.string(shellCommand))
            end tell
            """
        } else {
            // Terminal.app's "do script" without an `in window` clause
            // also opens a new window — there's no native new-tab op.
            // Fall back to AppleScript that targets front window if any.
            script = """
            tell application "Terminal"
                activate
                if (count of windows) > 0 then
                    do script \(AppleScriptEscape.string(shellCommand)) in front window
                else
                    do script \(AppleScriptEscape.string(shellCommand))
                end if
            end tell
            """
        }
        try OSAScript.run(script: script, terminalID: id, recorder: recorder, recordExecutable: "/usr/bin/osascript", recordArguments: ["-e", script], newWindow: newWindow)
    }
}

/// AppleScript-based launcher for iTerm2.
///
/// We deliberately do NOT pass the ssh command via iTerm's `command`
/// parameter to `create tab/window`. That bypasses the user's shell —
/// when ssh exits (cleanly daemonizing -fNM, or failing during connect)
/// the tab either auto-closes or sits blank, with no shell prompt and
/// no error visible to the user. We saw this exact failure mode on
/// FIDO hosts whose second-hop auth failed: the user only saw an empty
/// iTerm tab and had no idea what went wrong.
///
/// Instead, we let iTerm spawn the user's default profile (their shell),
/// then `write text` the ssh command in as typed input. iTerm queues
/// the text until the shell is ready, so no race. After ssh exits the
/// user sees the exit status + shell prompt and can ^C to abort or
/// re-run as needed.
public struct ITerm2Launcher: TerminalLauncher {
    public let id: TerminalID = .iterm2
    public let recorder: TerminalLaunchRecorder?
    public init(recorder: TerminalLaunchRecorder? = nil) { self.recorder = recorder }

    public func launch(argv: [String], newWindow: Bool, environment: [String: String]) throws {
        let shellCommand = ArgvShell.quote(argv)
        let escaped = AppleScriptEscape.string(shellCommand)
        let script: String
        if newWindow {
            script = """
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text \(escaped)
                end tell
            end tell
            """
        } else {
            script = """
            tell application "iTerm"
                activate
                if (count of windows) > 0 then
                    tell current window
                        set newTab to (create tab with default profile)
                        tell current session of newTab
                            write text \(escaped)
                        end tell
                    end tell
                else
                    set newWindow to (create window with default profile)
                    tell current session of newWindow
                        write text \(escaped)
                    end tell
                end if
            end tell
            """
        }
        try OSAScript.run(script: script, terminalID: id, recorder: recorder, recordExecutable: "/usr/bin/osascript", recordArguments: ["-e", script], newWindow: newWindow)
    }
}

/// Helper: run an AppleScript via /usr/bin/osascript. Detects the
/// errAEEventNotPermitted (-1743) failure mode produced when the user
/// has denied Automation permission and surfaces it as
/// TerminalLaunchError.automationDenied so the UI can prompt the user
/// to open System Settings → Privacy & Security → Automation.
enum OSAScript {
    static func run(
        script: String,
        terminalID: TerminalID,
        recorder: TerminalLaunchRecorder?,
        recordExecutable: String,
        recordArguments: [String],
        newWindow: Bool
    ) throws {
        if let recorder {
            recorder.record(executable: recordExecutable, arguments: recordArguments, newWindow: newWindow)
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            throw TerminalLaunchError.spawnFailed("osascript: \(error.localizedDescription)")
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if stderr.contains("-1743") || stderr.contains("not allowed") {
                throw TerminalLaunchError.automationDenied(terminalID)
            }
            throw TerminalLaunchError.spawnFailed("osascript exited \(proc.terminationStatus): \(stderr)")
        }
    }
}
