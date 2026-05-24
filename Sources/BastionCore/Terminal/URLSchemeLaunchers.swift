import Foundation

/// URL-scheme launcher for Warp.
/// Warp's URL scheme accepts `warp://action/new_tab?command=<percent-encoded>`
/// and `warp://action/new_window?command=...`.
public struct WarpLauncher: TerminalLauncher {
    public let id: TerminalID = .warp
    public let recorder: TerminalLaunchRecorder?
    public init(recorder: TerminalLaunchRecorder? = nil) { self.recorder = recorder }

    public func launch(argv: [String], newWindow: Bool, environment: [String: String]) throws {
        let shellCommand = ArgvShell.quote(argv)
        let action = newWindow ? "new_window" : "new_tab"
        guard var components = URLComponents(string: "warp://action/\(action)") else {
            throw TerminalLaunchError.spawnFailed("could not construct warp URL")
        }
        components.queryItems = [URLQueryItem(name: "command", value: shellCommand)]
        guard let url = components.url else {
            throw TerminalLaunchError.spawnFailed("URL construction failed")
        }
        try OpenURL.run(url: url.absoluteString, terminalID: id, recorder: recorder, newWindow: newWindow)
    }
}

/// URL-scheme launcher for Tabby. Scheme: `tabby:///run?command=<encoded>`.
public struct TabbyLauncher: TerminalLauncher {
    public let id: TerminalID = .tabby
    public let recorder: TerminalLaunchRecorder?
    public init(recorder: TerminalLaunchRecorder? = nil) { self.recorder = recorder }

    public func launch(argv: [String], newWindow: Bool, environment: [String: String]) throws {
        let shellCommand = ArgvShell.quote(argv)
        guard var components = URLComponents(string: "tabby:///run") else {
            throw TerminalLaunchError.spawnFailed("could not construct tabby URL")
        }
        components.queryItems = [URLQueryItem(name: "command", value: shellCommand)]
        guard let url = components.url else {
            throw TerminalLaunchError.spawnFailed("URL construction failed")
        }
        try OpenURL.run(url: url.absoluteString, terminalID: id, recorder: recorder, newWindow: newWindow)
    }
}

/// Hyper launcher — no robust command-launch story. Falls back to copying
/// the command to the clipboard and opening Hyper; the menu app surfaces
/// a banner explaining the user needs to paste.
public struct HyperLauncher: TerminalLauncher {
    public let id: TerminalID = .hyper
    public let recorder: TerminalLaunchRecorder?
    public init(recorder: TerminalLaunchRecorder? = nil) { self.recorder = recorder }

    public func launch(argv: [String], newWindow: Bool, environment: [String: String]) throws {
        if let recorder {
            // For tests, record what we would have done.
            recorder.record(executable: "/usr/bin/open", arguments: ["-a", "Hyper"], newWindow: newWindow)
            return
        }
        // Best-effort: open Hyper and surface a structured error so the
        // UI can prompt the user.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Hyper"]
        proc.environment = environment
        do { try proc.run() } catch {
            throw TerminalLaunchError.notInstalled(id)
        }
        throw TerminalLaunchError.unsupportedOperation(
            id,
            reason: "Hyper does not support command launch. Bastion has copied the SSH command to your clipboard — paste it into the Hyper window. See the menu bar for details."
        )
    }
}

/// Helper: open a URL via /usr/bin/open.
enum OpenURL {
    static func run(url: String, terminalID: TerminalID, recorder: TerminalLaunchRecorder?, newWindow: Bool) throws {
        if let recorder {
            recorder.record(executable: "/usr/bin/open", arguments: [url], newWindow: newWindow)
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [url]
        do { try proc.run() } catch {
            throw TerminalLaunchError.spawnFailed("open \(url): \(error.localizedDescription)")
        }
    }
}
