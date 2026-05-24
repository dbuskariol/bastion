import Foundation

/// Base for terminals invoked via `open -na <App> --args -e <argv...>`
/// or directly via their CLI binary. Subclasses (well, value types) tell
/// us the bundle id, CLI binary, and argv shape.
struct POSIXEvLauncher: TerminalLauncher {
    public let id: TerminalID
    public let recorder: TerminalLaunchRecorder?

    /// CLI binary name. If non-nil + present on PATH, prefer it.
    let cliBinary: String?
    /// App bundle path resolver — used as fallback if CLI not on PATH.
    let appPath: String?
    /// argv prefix the terminal expects BEFORE the command argv.
    /// e.g. ["-e"] for `alacritty -e ssh foo`, ["start", "--"] for `wezterm`.
    let cliArgvPrefix: [String]
    /// Same, but for the `open -na <app> --args <prefix> <command>` form.
    let openArgvPrefix: [String]

    func launch(argv: [String], newWindow: Bool, environment: [String: String]) throws {
        // Always use the CLI binary when available — cleanest behaviour,
        // best argv hygiene.
        if let cli = cliBinary {
            let exe = cliPath(named: cli, environment: environment)
            if let exe {
                try spawn(executable: exe, arguments: cliArgvPrefix + argv,
                          environment: environment, newWindow: newWindow)
                return
            }
        }
        // Fall back to open -na <app>. macOS spawns a new instance with
        // -n; without that, repeated invocations might reuse existing.
        guard let app = appPath else {
            throw TerminalLaunchError.notInstalled(id)
        }
        let openArgs = ["-na", app, "--args"] + openArgvPrefix + argv
        try spawn(executable: "/usr/bin/open", arguments: openArgs,
                  environment: environment, newWindow: newWindow)
    }

    private func cliPath(named binary: String, environment: [String: String]) -> String? {
        guard let pathString = environment["PATH"] else { return nil }
        for piece in pathString.split(separator: ":") {
            let candidate = "\(piece)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func spawn(executable: String, arguments: [String], environment: [String: String], newWindow: Bool) throws {
        if let recorder {
            recorder.record(executable: executable, arguments: arguments, newWindow: newWindow)
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.environment = environment
        do { try proc.run() } catch {
            throw TerminalLaunchError.spawnFailed("\(executable): \(error.localizedDescription)")
        }
        // We deliberately do not waitUntilExit — these are user-visible
        // long-lived processes.
    }
}

public struct GhosttyLauncher: TerminalLauncher {
    public let id: TerminalID = .ghostty
    public let recorder: TerminalLaunchRecorder?
    public let appPath: String?
    public init(appPath: String? = "/Applications/Ghostty.app", recorder: TerminalLaunchRecorder? = nil) {
        self.appPath = appPath
        self.recorder = recorder
    }
    public func launch(argv: [String], newWindow: Bool, environment: [String: String]) throws {
        try POSIXEvLauncher(
            id: id, recorder: recorder,
            cliBinary: "ghostty", appPath: appPath,
            cliArgvPrefix: ["-e"], openArgvPrefix: ["-e"]
        ).launch(argv: argv, newWindow: newWindow, environment: environment)
    }
}

public struct AlacrittyLauncher: TerminalLauncher {
    public let id: TerminalID = .alacritty
    public let recorder: TerminalLaunchRecorder?
    public let appPath: String?
    public init(appPath: String? = "/Applications/Alacritty.app", recorder: TerminalLaunchRecorder? = nil) {
        self.appPath = appPath
        self.recorder = recorder
    }
    public func launch(argv: [String], newWindow: Bool, environment: [String: String]) throws {
        try POSIXEvLauncher(
            id: id, recorder: recorder,
            cliBinary: "alacritty", appPath: appPath,
            cliArgvPrefix: ["-e"], openArgvPrefix: ["-e"]
        ).launch(argv: argv, newWindow: newWindow, environment: environment)
    }
}

public struct KittyLauncher: TerminalLauncher {
    public let id: TerminalID = .kitty
    public let recorder: TerminalLaunchRecorder?
    public let appPath: String?
    public init(appPath: String? = "/Applications/kitty.app", recorder: TerminalLaunchRecorder? = nil) {
        self.appPath = appPath
        self.recorder = recorder
    }
    public func launch(argv: [String], newWindow: Bool, environment: [String: String]) throws {
        // `kitty -- ssh foo` — `--` ends kitty's own flag parsing.
        // We use `kitten ssh` deliberately NOT because it clones shell
        // config which the consensus said we don't want.
        try POSIXEvLauncher(
            id: id, recorder: recorder,
            cliBinary: "kitty", appPath: appPath,
            cliArgvPrefix: ["--"], openArgvPrefix: ["--"]
        ).launch(argv: argv, newWindow: newWindow, environment: environment)
    }
}

public struct WezTermLauncher: TerminalLauncher {
    public let id: TerminalID = .wezterm
    public let recorder: TerminalLaunchRecorder?
    public let appPath: String?
    public init(appPath: String? = "/Applications/WezTerm.app", recorder: TerminalLaunchRecorder? = nil) {
        self.appPath = appPath
        self.recorder = recorder
    }
    public func launch(argv: [String], newWindow: Bool, environment: [String: String]) throws {
        try POSIXEvLauncher(
            id: id, recorder: recorder,
            cliBinary: "wezterm", appPath: appPath,
            cliArgvPrefix: ["start", "--"], openArgvPrefix: ["start", "--"]
        ).launch(argv: argv, newWindow: newWindow, environment: environment)
    }
}

public struct RioLauncher: TerminalLauncher {
    public let id: TerminalID = .rio
    public let recorder: TerminalLaunchRecorder?
    public let appPath: String?
    public init(appPath: String? = "/Applications/Rio.app", recorder: TerminalLaunchRecorder? = nil) {
        self.appPath = appPath
        self.recorder = recorder
    }
    public func launch(argv: [String], newWindow: Bool, environment: [String: String]) throws {
        try POSIXEvLauncher(
            id: id, recorder: recorder,
            cliBinary: "rio", appPath: appPath,
            cliArgvPrefix: ["-e"], openArgvPrefix: ["-e"]
        ).launch(argv: argv, newWindow: newWindow, environment: environment)
    }
}
