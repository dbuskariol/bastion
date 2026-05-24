import Testing
import Foundation
@testable import BastionCore

@Suite("AppleScriptEscape")
struct AppleScriptEscapeTests {
    @Test func plainString() {
        #expect(AppleScriptEscape.string("hello") == "\"hello\"")
    }

    @Test func escapesDoubleQuotes() {
        #expect(AppleScriptEscape.string(#"hello "world""#) == #""hello \"world\"""#)
    }

    @Test func escapesBackslashes() {
        #expect(AppleScriptEscape.string(#"a\b"#) == #""a\\b""#)
    }

    @Test func unicodePassthrough() {
        #expect(AppleScriptEscape.string("héllo 😀") == "\"héllo 😀\"")
    }

    @Test func emptyString() {
        #expect(AppleScriptEscape.string("") == "\"\"")
    }
}

@Suite("ArgvShell.quote")
struct ArgvShellTests {
    @Test func simpleArgvJoinedWithSingleQuotes() {
        #expect(ArgvShell.quote(["ssh", "prod"]) == "'ssh' 'prod'")
    }

    @Test func argvWithSingleQuoteEscaped() {
        #expect(ArgvShell.quote(["echo", "don't"]) == "'echo' 'don'\\''t'")
    }

    @Test func argvWithSpaces() {
        #expect(ArgvShell.quote(["echo", "hello world"]) == "'echo' 'hello world'")
    }

    @Test func emptyArgv() {
        #expect(ArgvShell.quote([]) == "")
    }
}

@Suite("URLEncode")
struct URLEncodeTests {
    @Test func roundTripsSimpleCommand() {
        let encoded = URLEncode.queryComponent("ssh prod-db")
        #expect(encoded.contains("ssh"))
        #expect(!encoded.contains(" "))
    }
}

@Suite("TerminalLauncher argv (recorded)")
struct TerminalLauncherArgvTests {

    @Test func ghosttyEmitsDashEArgv() throws {
        let recorder = TerminalLaunchRecorder()
        let launcher = GhosttyLauncher(appPath: "/Applications/Ghostty.app", recorder: recorder)
        try launcher.launch(argv: ["ssh", "prod"], newWindow: false,
                            environment: ["PATH": "/usr/bin"])
        let calls = recorder.invocations
        #expect(calls.count == 1)
        let call = calls[0]
        #expect(call.executable == "/usr/bin/open")
        #expect(call.arguments.contains("-na"))
        #expect(call.arguments.contains("/Applications/Ghostty.app"))
        #expect(call.arguments.contains("-e"))
        #expect(call.arguments.contains("ssh"))
        #expect(call.arguments.contains("prod"))
    }

    @Test func alacrittyDashE() throws {
        let recorder = TerminalLaunchRecorder()
        let launcher = AlacrittyLauncher(appPath: "/Applications/Alacritty.app", recorder: recorder)
        try launcher.launch(argv: ["ssh", "host"], newWindow: false, environment: ["PATH": "/usr/bin"])
        #expect(recorder.invocations.first?.arguments.contains("-e") == true)
    }

    @Test func wezTermStartDashDash() throws {
        let recorder = TerminalLaunchRecorder()
        let launcher = WezTermLauncher(appPath: "/Applications/WezTerm.app", recorder: recorder)
        try launcher.launch(argv: ["ssh", "host"], newWindow: false, environment: ["PATH": "/usr/bin"])
        let args = recorder.invocations.first?.arguments ?? []
        #expect(args.contains("start"))
        #expect(args.contains("--"))
    }

    @Test func kittyDashDash() throws {
        let recorder = TerminalLaunchRecorder()
        let launcher = KittyLauncher(appPath: "/Applications/kitty.app", recorder: recorder)
        try launcher.launch(argv: ["ssh", "host"], newWindow: false, environment: ["PATH": "/usr/bin"])
        let args = recorder.invocations.first?.arguments ?? []
        #expect(args.contains("--"))
    }

    @Test func terminalAppUsesOsascript() throws {
        let recorder = TerminalLaunchRecorder()
        let launcher = TerminalAppLauncher(recorder: recorder)
        try launcher.launch(argv: ["ssh", "host with spaces"], newWindow: true, environment: [:])
        let call = recorder.invocations[0]
        #expect(call.executable == "/usr/bin/osascript")
        #expect(call.arguments[0] == "-e")
        let script = call.arguments[1]
        #expect(script.contains("Terminal"))
        #expect(script.contains("do script"))
        #expect(script.contains("'ssh'"))
        #expect(script.contains("'host with spaces'"))
    }

    @Test func iTerm2UsesOsascriptCreateTab() throws {
        let recorder = TerminalLaunchRecorder()
        let launcher = ITerm2Launcher(recorder: recorder)
        try launcher.launch(argv: ["ssh", "h"], newWindow: false, environment: [:])
        let script = recorder.invocations[0].arguments[1]
        #expect(script.contains("iTerm"))
        #expect(script.contains("create tab"))
    }

    @Test func warpUsesURLScheme() throws {
        let recorder = TerminalLaunchRecorder()
        let launcher = WarpLauncher(recorder: recorder)
        try launcher.launch(argv: ["ssh", "prod"], newWindow: false, environment: [:])
        let call = recorder.invocations[0]
        #expect(call.executable == "/usr/bin/open")
        #expect(call.arguments[0].hasPrefix("warp://action/new_tab"))
        #expect(call.arguments[0].contains("command="))
    }

    @Test func warpNewWindowUsesNewWindowAction() throws {
        let recorder = TerminalLaunchRecorder()
        let launcher = WarpLauncher(recorder: recorder)
        try launcher.launch(argv: ["ssh", "h"], newWindow: true, environment: [:])
        #expect(recorder.invocations[0].arguments[0].contains("new_window"))
    }

    @Test func tabbyUsesURLScheme() throws {
        let recorder = TerminalLaunchRecorder()
        let launcher = TabbyLauncher(recorder: recorder)
        try launcher.launch(argv: ["ssh", "host"], newWindow: false, environment: [:])
        #expect(recorder.invocations[0].arguments[0].hasPrefix("tabby:///run"))
    }
}

@Suite("TerminalLauncherFactory")
struct TerminalLauncherFactoryTests {
    @Test func mapsEveryIDToALauncherWithCorrectId() {
        let factory = TerminalLauncherFactory()
        for id in TerminalID.allCases {
            let launcher = factory.launcher(for: id)
            #expect(launcher.id == id, "factory returned wrong launcher for \(id)")
        }
    }
}

@Suite("TerminalDetector suggested default")
struct TerminalDetectorSuggestedTests {
    @Test func iterm2PreferredWhenInstalled() {
        let resolver = PathResolver(preloaded: "/usr/bin")
        let detector = TerminalDetector(
            whichResolver: WhichResolver(pathResolver: resolver),
            overrideAppPath: [
                .iterm2: "/Applications/iTerm.app",
                .ghostty: "/Applications/Ghostty.app",
                .terminal: "/System/Applications/Utilities/Terminal.app"
            ]
        )
        #expect(detector.suggestedDefault() == .iterm2)
    }

    @Test func ghosttyPreferredWhenIterm2Absent() {
        let resolver = PathResolver(preloaded: "/usr/bin")
        let detector = TerminalDetector(
            whichResolver: WhichResolver(pathResolver: resolver),
            overrideAppPath: [
                .iterm2: Optional<String>.none,
                .ghostty: "/Applications/Ghostty.app",
                .terminal: "/System/Applications/Utilities/Terminal.app"
            ]
        )
        #expect(detector.suggestedDefault() == .ghostty)
    }

    @Test func terminalAppFallback() {
        let resolver = PathResolver(preloaded: "/usr/bin")
        let allEntries: [(TerminalID, String?)] = TerminalID.allCases.map { id in
            (id, id == .terminal ? "/System/Applications/Utilities/Terminal.app" : nil)
        }
        let detector = TerminalDetector(
            whichResolver: WhichResolver(pathResolver: resolver),
            overrideAppPath: Dictionary(uniqueKeysWithValues: allEntries),
            overrideCLIPath: Dictionary(uniqueKeysWithValues: TerminalID.allCases.map { ($0, Optional<String>.none) })
        )
        #expect(detector.suggestedDefault() == .terminal)
    }
}
