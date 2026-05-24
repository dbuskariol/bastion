import Foundation
import BastionCore
import BastionIdentifiers

private let engine = ConnectionEngine()

// MARK: - list

func runList(_ args: [String]) async throws -> Int32 {
    let flags = try CLIFlags(args)
    let registry = try engine.loadRegistry()
    if flags.bool("json") {
        try printJSON(registry)
        return 0
    }
    if registry.hosts.isEmpty {
        print("No hosts. Add one with `bastion add <alias> --host <hostname>`.")
        return 0
    }
    let sorted = registry.hosts.sorted { $0.alias.lowercased() < $1.alias.lowercased() }
    for host in sorted {
        let userPart = host.user.map { "\($0)@" } ?? ""
        let portPart = host.port != 22 ? ":\(host.port)" : ""
        print("\(host.alias.padding(toLength: 24, withPad: " ", startingAt: 0)) \(userPart)\(host.hostname)\(portPart)")
    }
    return 0
}

// MARK: - show

func runShow(_ args: [String]) async throws -> Int32 {
    let flags = try CLIFlags(args)
    guard let alias = flags.positional.first else {
        throw CLIError.missingFlag("<alias>")
    }
    let registry = try engine.loadRegistry()
    guard let host = registry.host(named: alias) else {
        throw CLIError.engine(.unknownAlias(alias))
    }
    if flags.bool("json") {
        try printJSON(host)
        return 0
    }
    print("alias:    \(host.alias)")
    print("host:     \(host.hostname)")
    if let user = host.user { print("user:     \(user)") }
    print("port:     \(host.port)")
    if !host.identityFiles.isEmpty {
        print("identity: \(host.identityFiles.joined(separator: ", "))")
    }
    if host.controlMaster != .inherit {
        print("master:   \(host.controlMaster.rawValue) (persist: \(host.controlPersist.displayName))")
    }
    if !host.tags.isEmpty { print("tags:     \(host.tags.joined(separator: ", "))") }
    if !host.notes.isEmpty { print("notes:    \(host.notes)") }
    return 0
}

// MARK: - add

func runAdd(_ args: [String]) async throws -> Int32 {
    let flags = try CLIFlags(args)
    guard let alias = flags.positional.first else {
        throw CLIError.missingFlag("<alias>")
    }
    guard Alias.isValid(alias) else {
        throw CLIError.invalidValue(
            flag: "<alias>", value: alias,
            reason: "must match \(Alias.pattern)"
        )
    }
    let hostname = try flags.requireFirst("host")
    let host = ManagedHost(
        alias: alias,
        hostname: hostname,
        user: flags.first("user"),
        port: Int(flags.first("port") ?? "22") ?? 22,
        identityFiles: flags.all("identity"),
        controlMaster: try parseControlMaster(flags.first("control-master") ?? "inherit"),
        controlPersist: try parseControlPersist(flags.first("control-persist") ?? "inherit"),
        tags: flags.all("tag"),
        notes: flags.first("note") ?? ""
    )
    let result = try await engine.upsertHost(host, skipIntegrationPass: flags.bool("skip-integration"))
    if flags.bool("json") {
        try printJSON([
            "added": host.alias,
            "integrationPassed": "\(result.integrationPassed)",
            "isolationPassed": "\(result.isolationPassed)"
        ])
    } else {
        print("Added host \(host.alias) → \(host.hostname)")
        if !result.integrationMismatches.isEmpty {
            print("warning: integration-pass detected effective-config mismatches:")
            for (alias, mm) in result.integrationMismatches {
                for (k, v) in mm {
                    print("  \(alias).\(k): \(v)")
                }
            }
        }
    }
    return 0
}

// MARK: - edit

func runEdit(_ args: [String]) async throws -> Int32 {
    let flags = try CLIFlags(args)
    guard let alias = flags.positional.first else { throw CLIError.missingFlag("<alias>") }
    let registry = try engine.loadRegistry()
    guard var host = registry.host(named: alias) else {
        throw CLIError.engine(.unknownAlias(alias))
    }
    if let h = flags.first("host") { host.hostname = h }
    if let u = flags.first("user") { host.user = u.isEmpty ? nil : u }
    if let p = flags.first("port"), let n = Int(p) { host.port = n }
    if !flags.all("identity").isEmpty { host.identityFiles = flags.all("identity") }
    if let cm = flags.first("control-master") {
        host.controlMaster = try parseControlMaster(cm)
    }
    if let cp = flags.first("control-persist") {
        host.controlPersist = try parseControlPersist(cp)
    }
    if !flags.all("tag").isEmpty { host.tags = flags.all("tag") }
    if let note = flags.first("note") { host.notes = note }
    _ = try await engine.upsertHost(host, skipIntegrationPass: flags.bool("skip-integration"))
    print("Updated \(host.alias).")
    return 0
}

// MARK: - remove

func runRemove(_ args: [String]) async throws -> Int32 {
    let flags = try CLIFlags(args)
    guard let alias = flags.positional.first else { throw CLIError.missingFlag("<alias>") }
    try await engine.removeHost(alias)
    print("Removed \(alias).")
    return 0
}

// MARK: - connect

func runConnect(_ args: [String]) async throws -> Int32 {
    let flags = try CLIFlags(args)
    guard let alias = flags.positional.first else { throw CLIError.missingFlag("<alias>") }
    let registry = try engine.loadRegistry()
    guard registry.host(named: alias) != nil else {
        throw CLIError.engine(.unknownAlias(alias))
    }
    if flags.bool("print-only") {
        print("ssh \(alias)")
        return 0
    }
    // The CLI doesn't launch a terminal — that's the menu app's job
    // (TerminalLauncher requires AppleScript / URL schemes that only make
    // sense from a GUI context). For CLI users, exec /usr/bin/ssh directly.
    let env = ProcessInfo.processInfo.environment
    let argv = ["/usr/bin/ssh", alias]
    let cargs = argv.map { strdup($0) } + [nil]
    let cenv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    execve("/usr/bin/ssh", cargs.map { UnsafeMutablePointer(mutating: $0) }, cenv.map { UnsafeMutablePointer(mutating: $0) })
    throw CLIError.io("execve(/usr/bin/ssh) failed")
}

// MARK: - master

func runMaster(_ args: [String]) async throws -> Int32 {
    let flags = try CLIFlags(args)
    guard let sub = flags.positional.first else {
        throw CLIError.missingFlag("<start|stop|check>")
    }
    guard flags.positional.count >= 2 else { throw CLIError.missingFlag("<alias>") }
    let alias = flags.positional[1]
    switch sub {
    case "check":
        let state = try await engine.checkMaster(alias)
        if flags.bool("json") { try printJSON(state); return 0 }
        print("\(alias): \(state.status.rawValue)")
        if let pid = state.pid { print("  pid: \(pid)") }
        if let n = state.attachedSessions { print("  sessions: \(n)") }
        if let path = state.controlPath { print("  socket: \(path)") }
        return 0
    case "start":
        let result = try await engine.establishBackgroundMaster(alias)
        if result.exitCode != 0 {
            fputs("Master could not be established in background (BatchMode=yes failed).\n", stderr)
            fputs("Open a terminal and run: ssh \(alias)\n", stderr)
            fputs(result.stderr, stderr)
            return result.exitCode
        }
        print("Master established for \(alias).")
        return 0
    case "stop":
        let result = try await engine.stopMaster(alias)
        print("Master closed for \(alias). (\(result.exitCode == 0 ? "ok" : "non-zero exit"))")
        return 0
    default:
        throw CLIError.unknown(verb: "master \(sub)")
    }
}

// MARK: - terminal

func runTerminal(_ args: [String]) async throws -> Int32 {
    let flags = try CLIFlags(args)
    guard let sub = flags.positional.first else {
        throw CLIError.missingFlag("<list|set>")
    }
    switch sub {
    case "list":
        // Full TerminalDetector lands in commit 7; commit 5 prints the
        // canonical list with installation status.
        let detector = StubTerminalDetector()
        let snapshots = TerminalID.allCases.map { detector.snapshot(for: $0) }
        if flags.bool("json") { try printJSON(snapshots); return 0 }
        for s in snapshots {
            let mark = s.installed ? "✓" : "·"
            print("\(mark) \(s.id.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))  \(s.id.displayName)\(s.appPath.map { "  (\($0))" } ?? "")")
        }
        return 0
    case "set":
        guard flags.positional.count >= 2 else { throw CLIError.missingFlag("<id>") }
        let raw = flags.positional[1]
        guard let id = TerminalID(rawValue: raw) else {
            throw CLIError.invalidValue(flag: "<id>", value: raw,
                                        reason: "must be one of \(TerminalID.allCases.map { $0.rawValue }.joined(separator: ","))")
        }
        try PreferencesStore.shared.setDefaultTerminal(id)
        print("Default terminal set to \(id.displayName).")
        return 0
    default:
        throw CLIError.unknown(verb: "terminal \(sub)")
    }
}

// MARK: - status

func runStatus(_ args: [String]) async throws -> Int32 {
    let flags = try CLIFlags(args)
    let report = await engine.snapshot(appVersion: BastionVersion.value)
    if flags.bool("json") {
        let json = try StatusReportJSON.encode(report)
        print(json)
        return 0
    }
    print("Bastion \(report.appVersion)")
    if let v = report.sshBinaryVersion { print("ssh:        \(v)") }
    print("agent:      \(report.agentReachable ? "reachable" : "unavailable")\(report.oneOnePasswordAgentDetected ? " (1Password)" : "")")
    print("include:    \(report.includeInstalled ? "installed" : "NOT installed (run `bastion config install-include`)")")
    print("hosts:      \(report.hosts.count)")
    if report.iCloudSyncSuspected {
        print("⚠️  ~/.ssh appears to be synced across Macs — concurrent edits may conflict.")
    }
    for h in report.hosts {
        print("  \(h.alias) → \(h.controlMaster.status.rawValue)")
    }
    return 0
}

// MARK: - config

func runConfig(_ args: [String]) async throws -> Int32 {
    let flags = try CLIFlags(args)
    guard let sub = flags.positional.first else {
        throw CLIError.missingFlag("<doctor|sync|install-include|remove-include>")
    }
    switch sub {
    case "doctor":
        let report = await engine.snapshot(appVersion: BastionVersion.value)
        if flags.bool("json") { try printJSON(report); return 0 }
        printDoctor(report)
        return 0
    case "sync":
        let registry = try engine.loadRegistry()
        _ = try await ConnectionEngine().managedWriter.write(registry, skipIntegrationPass: flags.bool("skip-integration"))
        print("Rewrote \(Paths.managedConfigFile.path).")
        return 0
    case "install-include":
        let scanner = UserSSHConfigScanner()
        let outcome = try scanner.ensureIncludeInstalled()
        print("Include install: \(outcome)")
        return 0
    case "remove-include":
        let scanner = UserSSHConfigScanner()
        let removed = try scanner.removeInclude()
        print(removed ? "Sentinel block removed." : "Sentinel block was not present.")
        return 0
    default:
        throw CLIError.unknown(verb: "config \(sub)")
    }
}

private func printDoctor(_ report: StatusReport) {
    print("== Bastion doctor ==")
    print("schema:     v\(report.schemaVersion)")
    print("app:        \(report.appVersion)")
    if let v = report.sshBinaryVersion { print("ssh:        \(v)") }
    print("agent:      \(report.agentReachable ? "reachable" : "unavailable")")
    if report.oneOnePasswordAgentDetected {
        print("  ⚠️  1Password SSH agent detected — Bastion will not call ssh-add against it.")
    }
    print("include:    \(report.includeInstalled ? "installed" : "MISSING")")
    if report.iCloudSyncSuspected {
        print("  ⚠️  Multi-Mac sync of ~/.ssh suspected (fingerprint mismatch).")
    }
    print("hosts:      \(report.hosts.count)")
    for h in report.hosts {
        print("  - \(h.alias) → \(h.hostname):\(h.port) master=\(h.controlMaster.status.rawValue) sessions=\(h.controlMaster.attachedSessions.map(String.init) ?? "—")")
    }
}

// MARK: - import (stub — full impl in commit 6)

func runImport(_ args: [String]) async throws -> Int32 {
    fputs("Import lands in commit 6 of the rollout — not yet wired through this CLI.\n", stderr)
    fputs("Source requested: \(args.first ?? "(none)")\n", stderr)
    return 2
}

// MARK: - uninstall

func runUninstall(_ args: [String]) async throws -> Int32 {
    let flags = try CLIFlags(args)
    let scanner = UserSSHConfigScanner()
    let writer = ManagedConfigWriter()
    _ = try scanner.removeInclude()
    try writer.removeManagedFile()
    // Clear Keychain index file but leave the actual Keychain items
    // alone (commit 9 manages those — until then there are no items to
    // delete).
    try? FileManager.default.removeItem(at: Paths.keychainIndexFile)
    if !flags.bool("keep-keys") {
        // Generated keys live in ~/.ssh/bastion_* — but per the rubber-duck
        // pass we leave them in place by default (user secrets, not app
        // data). --keep-keys is the no-op default; --no-keep-keys would
        // be the destructive path which we don't expose without an
        // interactive confirm. Print the file paths for transparency.
        let ssh = Paths.userSSHDirectory
        if let entries = try? FileManager.default.contentsOfDirectory(at: ssh, includingPropertiesForKeys: nil) {
            let ours = entries.filter { $0.lastPathComponent.hasPrefix("bastion_") }
            if !ours.isEmpty {
                print("Note: \(ours.count) Bastion-generated SSH key file(s) remain in ~/.ssh/:")
                for url in ours { print("  - \(url.lastPathComponent)") }
                print("Remove them yourself if no longer needed.")
            }
        }
    }
    print("Bastion uninstalled. Sentinel Include removed; bastion.conf deleted.")
    return 0
}

// MARK: - Stubs for components that land in later commits

/// Minimal terminal-detection stub. Commit 7 replaces with a full
/// LSCopyApplicationURLsForBundleIdentifier-based detector.
struct StubTerminalDetector {
    func snapshot(for id: TerminalID) -> TerminalSnapshot {
        let appPath = "/Applications/\(id.displayName).app"
        let installed = FileManager.default.fileExists(atPath: appPath)
        return TerminalSnapshot(id: id, installed: installed, appPath: installed ? appPath : nil)
    }
}

/// Lazy stand-in for the per-process preferences file. Replaced fully in
/// commit 8 with the SwiftUI menu app's preferences plumbing; CLI just
/// needs to round-trip the default-terminal id.
final class PreferencesStore: @unchecked Sendable {
    static let shared = PreferencesStore()
    private let file = Paths.preferencesFile
    private struct Payload: Codable {
        var schemaVersion: Int
        var defaultTerminal: TerminalID?
    }
    func setDefaultTerminal(_ id: TerminalID) throws {
        try Paths.ensureAppSupportDirectoryExists()
        var payload = (try? load()) ?? Payload(schemaVersion: 1, defaultTerminal: nil)
        payload.defaultTerminal = id
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: file, options: .atomic)
    }
    func defaultTerminal() -> TerminalID? {
        (try? load())?.defaultTerminal
    }
    private func load() throws -> Payload {
        let data = try Data(contentsOf: file)
        return try JSONDecoder().decode(Payload.self, from: data)
    }
}
