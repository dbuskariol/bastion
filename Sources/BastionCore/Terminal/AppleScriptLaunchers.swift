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
                create window with default profile command \(escaped)
            end tell
            """
        } else {
            script = """
            tell application "iTerm"
                activate
                if (count of windows) > 0 then
                    tell current window to create tab with default profile command \(escaped)
                else
                    create window with default profile command \(escaped)
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
