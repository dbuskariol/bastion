import Testing
import Foundation
@testable import BastionCore

@Suite("SSHCheckParser")
struct SSHCheckParserTests {
    @Test func parsesPidFromStandardOutput() {
        #expect(SSHCheckParser.parseMasterPid("Master running (pid=12345)") == 12345)
        #expect(SSHCheckParser.parseMasterPid("Master running (pid=987654)") == 987654)
    }

    @Test func returnsNilForOutputWithoutPid() {
        #expect(SSHCheckParser.parseMasterPid("") == nil)
        #expect(SSHCheckParser.parseMasterPid("Bad day") == nil)
    }

    @Test func indicatesMasterRunningCaseInsensitive() {
        #expect(SSHCheckParser.indicatesMasterRunning("Master running (pid=1)"))
        #expect(SSHCheckParser.indicatesMasterRunning("master running"))
        #expect(!SSHCheckParser.indicatesMasterRunning("Connection refused"))
    }

    @Test func indicatesSocketMissing() {
        #expect(SSHCheckParser.indicatesSocketMissing("connect to control socket: No such file or directory"))
        #expect(SSHCheckParser.indicatesSocketMissing("Control socket connect(...): foo"))
        #expect(!SSHCheckParser.indicatesSocketMissing("Master running"))
    }
}

@Suite("SSHAgentProbe")
struct SSHAgentProbeTests {
    @Test func unavailableWhenSocketUnset() {
        let probe = SSHAgentProbe(environment: [:])
        #expect(probe.detect() == .unavailable)
        #expect(!probe.canAddKeys)
    }

    @Test func appleLaunchdSocketDetected() {
        let probe = SSHAgentProbe(environment: [
            "SSH_AUTH_SOCK": "/private/tmp/com.apple.launchd.abc/Listeners"
        ])
        #expect(probe.detect() == .appleLaunchd)
        #expect(probe.canAddKeys)
    }

    @Test func onePasswordAgentDetectedAndSkipped() {
        let probe = SSHAgentProbe(environment: [
            "SSH_AUTH_SOCK": "/Users/dan/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
        ])
        #expect(probe.detect() == .onePassword)
        #expect(!probe.canAddKeys, "must not try to ssh-add against 1Password agent")
    }

    @Test func secretiveDetected() {
        let probe = SSHAgentProbe(environment: [
            "SSH_AUTH_SOCK": "/Users/dan/Library/Containers/com.maxgoedjen.Secretive.Agent/Data/socket.ssh"
        ])
        #expect(probe.detect() == .secretive)
        #expect(!probe.canAddKeys)
    }

    @Test func unknownAgentTreatedAsOther() {
        let probe = SSHAgentProbe(environment: [
            "SSH_AUTH_SOCK": "/var/run/some-agent.sock"
        ])
        #expect(probe.detect() == .other)
        #expect(probe.canAddKeys)
    }
}

@Suite("PathResolver")
struct PathResolverTests {
    @Test func unionDeduplicatesAndPreservesOrder() {
        let result = PathResolver.union("/a:/b:/c", "/b:/d:/a:/e")
        #expect(result == "/a:/b:/c:/d:/e")
    }

    @Test func preloadedValueIsReturnedDirectly() {
        let resolver = PathResolver(preloaded: "/opt/test/bin")
        #expect(resolver.path() == "/opt/test/bin")
    }

    @Test func environmentInjectsPATH() {
        let resolver = PathResolver(preloaded: "/opt/test/bin")
        let env = resolver.environment(adding: ["FOO": "bar"])
        #expect(env["PATH"] == "/opt/test/bin")
        #expect(env["FOO"] == "bar")
    }
}

@Suite("WhichResolver")
struct WhichResolverTests {
    @Test func findsExecutableOnInjectedPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bastion-which-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeBin = dir.appendingPathComponent("bastion-fake-tool")
        try "#!/bin/sh\necho ok".write(to: fakeBin, atomically: true, encoding: .utf8)
        var attrs = try FileManager.default.attributesOfItem(atPath: fakeBin.path)
        attrs[FileAttributeKey.posixPermissions] = NSNumber(value: 0o755)
        try FileManager.default.setAttributes(attrs, ofItemAtPath: fakeBin.path)

        let resolver = PathResolver(preloaded: dir.path)
        let which = WhichResolver(pathResolver: resolver)
        let found = which.which("bastion-fake-tool")
        #expect(found?.path == fakeBin.path)
        #expect(which.which("nope-does-not-exist") == nil)
    }
}

@Suite("StatusReportJSON")
struct StatusReportJSONTests {
    @Test func roundTrip() throws {
        let report = StatusReport(
            appVersion: "0.1.0",
            sshBinaryVersion: "OpenSSH_9.6p1",
            agentReachable: true,
            oneOnePasswordAgentDetected: false,
            defaultTerminal: .iterm2,
            includeInstalled: true,
            hosts: [
                HostSnapshot(
                    id: UUID(),
                    alias: "prod",
                    hostname: "prod.example.com",
                    user: "deploy",
                    port: 22,
                    controlMaster: ControlMasterState(
                        enabled: true, status: .running, controlPath: "/tmp/sock",
                        pid: 12345, establishedAt: Date(timeIntervalSince1970: 1_000_000),
                        attachedSessions: 2, persistSeconds: 28800,
                        lastCheckedAt: Date(timeIntervalSince1970: 1_001_000)
                    )
                )
            ],
            terminals: [TerminalSnapshot(id: .iterm2, installed: true, appPath: "/Applications/iTerm.app")]
        )
        let encoded = try StatusReportJSON.encode(report)
        let decoded = try StatusReportJSON.decode(Data(encoded.utf8))
        #expect(decoded.appVersion == "0.1.0")
        #expect(decoded.hosts.first?.alias == "prod")
        #expect(decoded.hosts.first?.controlMaster.status == .running)
        #expect(decoded.terminals.first?.id == .iterm2)
    }

    @Test func schemaVersionPresent() {
        let report = StatusReport(appVersion: "0.1.0")
        #expect(report.schemaVersion == StatusReport.currentSchemaVersion)
    }
}

@Suite("MasterUptimeStore")
struct MasterUptimeStoreTests {
    @Test func recordSeenReturnsFirstObservation() {
        let store = MasterUptimeStore()
        let now = Date()
        let later = now.addingTimeInterval(60)
        _ = store.recordSeen(alias: "x-first-\(UUID())", at: now)
        let alias = "x-stable-\(UUID())"
        _ = store.recordSeen(alias: alias, at: now)
        let second = store.recordSeen(alias: alias, at: later)
        #expect(second == now)
    }
}

@Suite("TerminalID")
struct TerminalIDTests {
    @Test func bundleIdsAreUniqueAndStable() {
        let bundleIDs = TerminalID.allCases.map { $0.bundleIdentifier }
        #expect(bundleIDs.count == Set(bundleIDs).count, "duplicate bundle IDs")
    }

    @Test func displayNamesNonEmpty() {
        for id in TerminalID.allCases {
            #expect(!id.displayName.isEmpty)
            #expect(!id.bundleIdentifier.isEmpty)
        }
    }
}
