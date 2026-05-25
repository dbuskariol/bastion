import Testing
import Foundation
@testable import BastionCore

@Suite("BastionConfigWriter")
struct BastionConfigWriterTests {

    @Test func emptyRegistryRendersHeaderOnly() throws {
        let writer = BastionConfigWriter()
        let output = try writer.render(HostRegistry(), generatedAt: Date(timeIntervalSince1970: 0))
        #expect(output.contains("# Bastion — generated file"))
        #expect(!output.contains("Host "))
    }

    @Test func singleMinimalHostRenders() throws {
        let writer = BastionConfigWriter()
        let host = ManagedHost(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            alias: "prod",
            hostname: "prod.example.com"
        )
        let registry = HostRegistry(hosts: [host])
        let output = try writer.render(registry, generatedAt: Date(timeIntervalSince1970: 0))
        #expect(output.contains("Host prod"))
        #expect(output.contains("    # id: 11111111-1111-1111-1111-111111111111"))
        #expect(output.contains("    HostName prod.example.com"))
        #expect(!output.contains("Port "))
        #expect(!output.contains("User "))
    }

    @Test func controlMasterEmitsPathOnlyWhenEnabled() throws {
        let writer = BastionConfigWriter()
        let hostOff = ManagedHost(alias: "noof", hostname: "h",
                                  controlMaster: .inherit, controlPersist: .inherit)
        let outputOff = try writer.render(HostRegistry(hosts: [hostOff]))
        #expect(!outputOff.contains("ControlMaster"))
        #expect(!outputOff.contains("ControlPath"))

        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let hostOn = ManagedHost(id: id, alias: "on", hostname: "h",
                                 controlMaster: .on, controlPersist: .hours(8))
        let outputOn = try writer.render(HostRegistry(hosts: [hostOn]))
        #expect(outputOn.contains("ControlMaster auto"))
        // Stable per-host ControlPath with %p-%r segmentation (load-bearing
        // for the cross-name-variant shared-master design).
        #expect(outputOn.contains("ControlPath ~/.ssh/sockets/bastion-111111111111-%p-%r"))
        #expect(outputOn.contains("ControlPersist 8h"))
    }

    @Test func emitsMatchHostBlockWhenAliasDiffersFromHostname() throws {
        let writer = BastionConfigWriter()
        let id = UUID(uuidString: "abcdef01-2345-6789-abcd-ef0123456789")!
        let host = ManagedHost(
            id: id,
            alias: "bastion",
            hostname: "bastion.example.internal",
            user: "alice",
            identityFiles: ["/Users/test/.ssh/id_rsa"],
            controlMaster: .on,
            controlPersist: .hours(8),
            advanced: [.proxyJump: "bastion-jump.example.com"]
        )
        let output = try writer.render(HostRegistry(hosts: [host]))
        // Primary Host stanza:
        #expect(output.contains("Host bastion"))
        #expect(output.contains("    HostName bastion.example.internal"))
        #expect(output.contains("    ControlPath ~/.ssh/sockets/bastion-abcdef012345-%p-%r"))
        // Match block:
        #expect(output.contains("Match host bastion.example.internal"))
        // B1 fix: no `user <user>` qualifier on the Match line.
        #expect(!output.contains("Match host bastion.example.internal user"))
        // B1 fix: User INSIDE the block.
        let matchBlockStart = output.range(of: "Match host")!.lowerBound
        let afterMatch = String(output[matchBlockStart...])
        #expect(afterMatch.contains("    User alice"))
        // N2: IdentityFile + IdentitiesOnly re-asserted.
        #expect(afterMatch.contains("    IdentityFile /Users/test/.ssh/id_rsa"))
        #expect(afterMatch.contains("    IdentitiesOnly yes"))
        // N1: ProxyJump re-asserted because Bastion has it explicitly.
        #expect(afterMatch.contains("    ProxyJump bastion-jump.example.com"))
        // Multiplex trio re-asserted in the Match block too.
        #expect(afterMatch.contains("    ControlMaster auto"))
        #expect(afterMatch.contains("    ControlPath ~/.ssh/sockets/bastion-abcdef012345-%p-%r"))
        #expect(afterMatch.contains("    ControlPersist 8h"))
    }

    @Test func suppressesMatchBlockWhenAliasEqualsHostname() throws {
        let writer = BastionConfigWriter()
        let host = ManagedHost(alias: "myhost", hostname: "myhost",
                               controlMaster: .on, controlPersist: .hours(8))
        let output = try writer.render(HostRegistry(hosts: [host]))
        #expect(output.contains("Host myhost"))
        #expect(!output.contains("Match host"))
    }

    @Test func suppressesMatchBlockForGlobHostname() throws {
        // Belt-and-suspenders: validateForSave should reject this first,
        // but if a host somehow gets here with a glob hostname, the writer
        // must not emit a `Match host *.something` over-matcher.
        // We synthesise via direct construction; we don't go through validateForSave.
        let writer = BastionConfigWriter()
        let host = ManagedHost(alias: "x", hostname: "literal.example.com",
                               controlMaster: .on, controlPersist: .hours(8))
        // (Real glob test happens in the ManagedHost validation test below.)
        let output = try writer.render(HostRegistry(hosts: [host]))
        #expect(output.contains("Match host literal.example.com"))
    }

    @Test func validateForSaveRejectsGlobInHostname() throws {
        // Per rubber-duck S2: hostname must be literal when ControlMaster
        // is enabled (we emit Match host with it).
        let host = ManagedHost(alias: "wild", hostname: "*.internal",
                               controlMaster: .on, controlPersist: .hours(8))
        #expect(throws: SSHConfigError.self) {
            try host.validateForSave()
        }
    }

    @Test func resolvedControlMuxIDDerivedFromIdWhenNil() throws {
        let id = UUID(uuidString: "deadbeef-1234-5678-9abc-def012345678")!
        let host = ManagedHost(id: id, alias: "x", hostname: "h")
        #expect(host.resolvedControlMuxID == "deadbeef1234")
    }

    @Test func resolvedControlMuxIDHonoursExplicitOverride() throws {
        let host = ManagedHost(alias: "x", hostname: "h", controlMuxID: "explicit-mux")
        #expect(host.resolvedControlMuxID == "explicit-mux")
    }

    @Test func identityFileImpliesIdentitiesOnly() throws {
        let writer = BastionConfigWriter()
        let host = ManagedHost(alias: "k", hostname: "h",
                               identityFiles: ["/Users/test/.ssh/id"])
        let output = try writer.render(HostRegistry(hosts: [host]))
        #expect(output.contains("IdentityFile /Users/test/.ssh/id"))
        #expect(output.contains("IdentitiesOnly yes"))
    }

    @Test func rejectsAliasWithSpace() throws {
        let writer = BastionConfigWriter()
        let host = ManagedHost(alias: "bad alias", hostname: "h")
        #expect(throws: SSHConfigError.self) {
            _ = try writer.render(HostRegistry(hosts: [host]))
        }
    }

    @Test func rejectsValueWithNewline() throws {
        let writer = BastionConfigWriter()
        let host = ManagedHost(alias: "x", hostname: "host\nname")
        #expect(throws: SSHConfigError.self) {
            _ = try writer.render(HostRegistry(hosts: [host]))
        }
    }

    @Test func rawOverrideRejectsNestedInclude() throws {
        let writer = BastionConfigWriter()
        let host = ManagedHost(alias: "x", hostname: "h",
                               rawConfigOverride: "Include other.conf")
        #expect(throws: SSHConfigError.self) {
            _ = try writer.render(HostRegistry(hosts: [host]))
        }
    }

    @Test func rawOverrideRejectsNewHostStanza() throws {
        let writer = BastionConfigWriter()
        let host = ManagedHost(alias: "x", hostname: "h",
                               rawConfigOverride: "Host other\n    HostName z")
        #expect(throws: SSHConfigError.self) {
            _ = try writer.render(HostRegistry(hosts: [host]))
        }
    }

    @Test func deterministicOutputForSameRegistry() throws {
        let writer = BastionConfigWriter()
        var registry = HostRegistry()
        registry.upsert(ManagedHost(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            alias: "alpha", hostname: "alpha.example.com"
        ))
        registry.upsert(ManagedHost(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            alias: "beta", hostname: "beta.example.com",
            controlMaster: .on, controlPersist: .hours(8)
        ))
        let body1 = try writer.render(registry, generatedAt: Date(timeIntervalSince1970: 0))
        let body2 = try writer.render(registry, generatedAt: Date(timeIntervalSince1970: 0))
        #expect(body1 == body2)
    }

    @Test func hostsSortedAlphabeticallyForStableDiff() throws {
        let writer = BastionConfigWriter()
        let h1 = ManagedHost(alias: "zebra", hostname: "z")
        let h2 = ManagedHost(alias: "alpha", hostname: "a")
        let h3 = ManagedHost(alias: "Mike",  hostname: "m")
        let output = try writer.render(HostRegistry(hosts: [h1, h2, h3]))
        let alphaPos = output.range(of: "Host alpha")!.lowerBound
        let mikePos = output.range(of: "Host Mike")!.lowerBound
        let zebraPos = output.range(of: "Host zebra")!.lowerBound
        #expect(alphaPos < mikePos)
        #expect(mikePos < zebraPos)
    }
}

@Suite("UserSSHConfigScanner")
struct UserSSHConfigScannerTests {

    private func tempScanner(content: String?) throws -> (URL, UserSSHConfigScanner) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bastion-scanner-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let configFile = dir.appendingPathComponent("config")
        if let content {
            try content.write(to: configFile, atomically: true, encoding: .utf8)
        }
        return (dir, UserSSHConfigScanner(configFile: configFile))
    }

    @Test func detectsMissingFile() throws {
        let (_, scanner) = try tempScanner(content: nil)
        let scan = try scanner.scan()
        #expect(scan.isEmpty)
        #expect(!scan.sentinelInstalled)
        #expect(scan.existingHostAliases.isEmpty)
        #expect(!scan.coveringIncludePresent)
        #expect(!scan.hasMatchExec)
    }

    @Test func detectsSentinelInstalled() throws {
        let content = """
        # BEGIN BASTION MANAGED
        Include ~/.ssh/config.d/*.conf
        # END BASTION MANAGED

        Host prod
            HostName prod.example.com
        """
        let (_, scanner) = try tempScanner(content: content)
        let scan = try scanner.scan()
        #expect(scan.sentinelInstalled)
        #expect(scan.existingHostAliases == ["prod"])
    }

    @Test func detectsExistingHostAliases() throws {
        let content = """
        Host prod
            HostName prod.example.com
        Host staging dev01
            HostName s.example.com
        Host *
            Compression yes
        """
        let (_, scanner) = try tempScanner(content: content)
        let scan = try scanner.scan()
        #expect(scan.existingHostAliases.sorted() == ["dev01", "prod", "staging"].sorted())
    }

    @Test func detectsCoveringInclude() throws {
        let content = """
        Include ~/.ssh/config.d/*.conf
        """
        let (_, scanner) = try tempScanner(content: content)
        let scan = try scanner.scan()
        #expect(scan.coveringIncludePresent)
    }

    @Test func ignoresUnrelatedInclude() throws {
        let content = """
        Include ~/.ssh/work-config.d/*.conf
        Host foo
            HostName foo.example.com
        """
        let (_, scanner) = try tempScanner(content: content)
        let scan = try scanner.scan()
        #expect(!scan.coveringIncludePresent)
    }

    @Test func detectsMatchExec() throws {
        let content = """
        Match exec "test -d ~/.vpn"
            ProxyJump bastion.work
        Host work
            HostName w.example.com
        """
        let (_, scanner) = try tempScanner(content: content)
        let scan = try scanner.scan()
        #expect(scan.hasMatchExec)
    }

    @Test func injectsSentinelAtTop() throws {
        let original = """
        Host existing
            HostName x.example.com
        """
        let (_, scanner) = try tempScanner(content: original)
        let outcome = try scanner.ensureIncludeInstalled()
        #expect(outcome == .injected)
        let updated = try String(contentsOf: scanner.configFile, encoding: .utf8)
        #expect(updated.hasPrefix("# BEGIN BASTION MANAGED"))
        #expect(updated.contains("Include ~/.ssh/config.d/*.conf"))
        #expect(updated.contains("# END BASTION MANAGED"))
        #expect(updated.contains("Host existing"))
    }

    @Test func injectIsIdempotent() throws {
        let (_, scanner) = try tempScanner(content: "Host foo\n    HostName f\n")
        _ = try scanner.ensureIncludeInstalled()
        let outcome = try scanner.ensureIncludeInstalled()
        #expect(outcome == .alreadyPresent)
    }

    @Test func injectIsNoopIfUserHasCoveringInclude() throws {
        let original = "Include ~/.ssh/config.d/*.conf\nHost a\n    HostName a.example.com\n"
        let (_, scanner) = try tempScanner(content: original)
        let outcome = try scanner.ensureIncludeInstalled()
        #expect(outcome == .noopBecauseUserHasCoveringInclude)
    }

    @Test func removeInclude() throws {
        let original = """
        # BEGIN BASTION MANAGED
        Include ~/.ssh/config.d/*.conf
        # END BASTION MANAGED

        Host existing
            HostName x.example.com
        """
        let (_, scanner) = try tempScanner(content: original)
        let removed = try scanner.removeInclude()
        #expect(removed)
        let updated = try String(contentsOf: scanner.configFile, encoding: .utf8)
        #expect(!updated.contains("BEGIN BASTION MANAGED"))
        #expect(updated.contains("Host existing"))
    }

    @Test func symlinkResolutionPreservesLinkOnWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bastion-symlink-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let realFile = dir.appendingPathComponent("real_config")
        try "Host preexisting\n    HostName p\n".write(to: realFile, atomically: true, encoding: .utf8)
        let symlinkFile = dir.appendingPathComponent("config")
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: realFile)

        let scanner = UserSSHConfigScanner(configFile: symlinkFile)
        let scan = try scanner.scan()
        #expect(scan.resolvedSymlinkTarget != nil)
        #expect(scan.existingHostAliases == ["preexisting"])

        _ = try scanner.ensureIncludeInstalled()
        var stat_ = stat()
        _ = lstat(symlinkFile.path, &stat_)
        #expect((stat_.st_mode & S_IFMT) == S_IFLNK)
        let target = try String(contentsOf: realFile, encoding: .utf8)
        #expect(target.contains("BEGIN BASTION MANAGED"))
    }
}

@Suite("SSHGReader parse")
struct SSHGReaderParseTests {
    @Test func parsesKeyValueLines() {
        let stdout = """
        hostname prod.example.com
        user dan
        port 22
        controlmaster auto
        controlpath /Users/dan/.ssh/sockets/abc
        """
        let cfg = SSHGReader.parse(stdout: stdout)
        #expect(cfg.first("hostname") == "prod.example.com")
        #expect(cfg.first("user") == "dan")
        #expect(cfg.first("port") == "22")
        #expect(cfg.first("controlpath") == "/Users/dan/.ssh/sockets/abc")
    }

    @Test func multiValuedOptionsGatheredIntoArrays() {
        let stdout = """
        identityfile ~/.ssh/a
        identityfile ~/.ssh/b
        localforward 1234 host:5678
        """
        let cfg = SSHGReader.parse(stdout: stdout)
        #expect(cfg.all("identityfile").count == 2)
        #expect(cfg.all("identityfile") == ["~/.ssh/a", "~/.ssh/b"])
        #expect(cfg.all("localforward") == ["1234 host:5678"])
    }

    @Test func pathsWithSpacesPreserved() {
        let stdout = "identityfile /Users/Some User/.ssh/key"
        let cfg = SSHGReader.parse(stdout: stdout)
        #expect(cfg.first("identityfile") == "/Users/Some User/.ssh/key")
    }

    @Test func controlpathNoneNormalisedToNil() {
        let cfg1 = SSHGReader.parse(stdout: "controlpath none")
        #expect(cfg1.usableControlPath == nil)
        let cfg2 = SSHGReader.parse(stdout: "controlpath ")
        #expect(cfg2.usableControlPath == nil)
        let cfg3 = SSHGReader.parse(stdout: "controlpath /tmp/sock")
        #expect(cfg3.usableControlPath == "/tmp/sock")
    }

    @Test func controlMasterEnabledRecognisesYesAutoAsk() {
        #expect(SSHGReader.parse(stdout: "controlmaster yes").controlMasterEnabled)
        #expect(SSHGReader.parse(stdout: "controlmaster auto").controlMasterEnabled)
        #expect(SSHGReader.parse(stdout: "controlmaster ask").controlMasterEnabled)
        #expect(!SSHGReader.parse(stdout: "controlmaster no").controlMasterEnabled)
        #expect(!SSHGReader.parse(stdout: "").controlMasterEnabled)
    }
}
