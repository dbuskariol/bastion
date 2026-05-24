import Testing
import Foundation
@testable import BastionCore

@Suite("HostRegistry")
struct HostRegistryTests {

    @Test func upsertInsertsNewHost() {
        var registry = HostRegistry()
        let host = ManagedHost(alias: "prod", hostname: "prod.example.com")
        registry.upsert(host)
        #expect(registry.hosts.count == 1)
        #expect(registry.host(named: "prod")?.id == host.id)
    }

    @Test func upsertUpdatesExistingByID() {
        var registry = HostRegistry()
        let host = ManagedHost(alias: "prod", hostname: "prod.example.com")
        registry.upsert(host)
        var updated = host
        updated.hostname = "prod2.example.com"
        registry.upsert(updated)
        #expect(registry.hosts.count == 1)
        #expect(registry.host(named: "prod")?.hostname == "prod2.example.com")
    }

    @Test func aliasIsAvailableExcludesSelf() {
        var registry = HostRegistry()
        let host = ManagedHost(alias: "prod", hostname: "prod.example.com")
        registry.upsert(host)
        #expect(registry.aliasIsAvailable("prod", excluding: host.id))
        #expect(!registry.aliasIsAvailable("prod"))
        #expect(registry.aliasIsAvailable("staging"))
    }

    @Test func aliasLookupIsCaseInsensitive() {
        var registry = HostRegistry()
        registry.upsert(ManagedHost(alias: "Prod", hostname: "p.example.com"))
        #expect(registry.host(named: "prod") != nil)
        #expect(registry.host(named: "PROD") != nil)
        #expect(!registry.aliasIsAvailable("prod"))
    }

    @Test func removeRemovesByID() {
        var registry = HostRegistry()
        let host = ManagedHost(alias: "prod", hostname: "prod.example.com")
        registry.upsert(host)
        registry.remove(host.id)
        #expect(registry.hosts.isEmpty)
    }
}

@Suite("Alias validation")
struct AliasValidationTests {
    @Test func validAliases() {
        let valid = ["prod", "prod-db", "prod_db", "prod.db", "prod1", "PROD", "a", "a-b-c.d_e"]
        for alias in valid {
            #expect(Alias.isValid(alias), "expected \(alias) to be valid")
        }
    }

    @Test func invalidAliases() {
        let invalid = ["", "prod db", "prod/db", "prod*", "prod?", "prod\nname", "prod;rm", "prod\\"]
        for alias in invalid {
            #expect(!Alias.isValid(alias), "expected \(alias.debugDescription) to be invalid")
        }
    }
}

@Suite("ControlPersistChoice")
struct ControlPersistChoiceTests {
    @Test func defaultIs8Hours() {
        #expect(ControlPersistChoice.defaultChoice == .hours(8))
    }

    @Test func configValueForms() {
        #expect(ControlPersistChoice.inherit.configValue == nil)
        #expect(ControlPersistChoice.minutes(10).configValue == "10m")
        #expect(ControlPersistChoice.hours(8).configValue == "8h")
        #expect(ControlPersistChoice.indefinite.configValue == "yes")
        #expect(ControlPersistChoice.disabled.configValue == "no")
    }
}

@Suite("SSHOption")
struct SSHOptionTests {
    @Test func multiValuedOptionsAreCorrect() {
        let multi: Set<SSHOption> = [
            .identityFile, .certificateFile,
            .localForward, .remoteForward, .dynamicForward,
            .sendEnv, .setEnv
        ]
        for option in SSHOption.allCases {
            #expect(
                option.isMultiValued == multi.contains(option),
                "SSHOption \(option.rawValue) multi-valued mismatch"
            )
        }
    }

    @Test func rawValueMatchesSshGOutputLowercase() {
        #expect(SSHOption.controlMaster.rawValue == "controlmaster")
        #expect(SSHOption.identityFile.rawValue == "identityfile")
        #expect(SSHOption.proxyJump.rawValue == "proxyjump")
        #expect(SSHOption.userKnownHostsFile.rawValue == "userknownhostsfile")
    }

    @Test func configKeysAreCamelCaseConventional() {
        #expect(SSHOption.controlMaster.configKey == "ControlMaster")
        #expect(SSHOption.identityFile.configKey == "IdentityFile")
        #expect(SSHOption.tcpKeepAlive.configKey == "TCPKeepAlive")
        #expect(SSHOption.pkcs11Provider.configKey == "PKCS11Provider")
        #expect(SSHOption.macs.configKey == "MACs")
    }
}
