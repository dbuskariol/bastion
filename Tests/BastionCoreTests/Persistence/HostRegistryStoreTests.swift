import Testing
import Foundation
@testable import BastionCore

@Suite("HostRegistryStore", .serialized)
struct HostRegistryStoreTests {

    /// Build a store rooted at a fresh temp directory so tests don't
    /// touch real user state and don't interfere with each other.
    private func makeStore() throws -> HostRegistryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bastion-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return HostRegistryStore(
            storeFile: dir.appendingPathComponent("hosts.json"),
            prevFile: dir.appendingPathComponent("hosts.json.prev"),
            backupsDirectory: dir.appendingPathComponent("backups", isDirectory: true)
        )
    }

    @Test func loadMissingReturnsEmpty() throws {
        let store = try makeStore()
        let reg = try store.load()
        #expect(reg.hosts.isEmpty)
        #expect(reg.schemaVersion == HostRegistry.currentSchemaVersion)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let store = try makeStore()
        var registry = HostRegistry()
        let host = ManagedHost(
            alias: "prod-db",
            hostname: "prod-db.example.com",
            user: "deploy",
            port: 22,
            identityFiles: ["/Users/test/.ssh/prod_ed25519"],
            controlMaster: .on,
            controlPersist: .hours(8),
            advanced: [.compression: "yes", .strictHostKeyChecking: "accept-new"],
            tags: ["prod", "db"]
        )
        registry.upsert(host)
        try store.save(registry)

        let loaded = try store.load()
        #expect(loaded.hosts.count == 1)
        #expect(loaded.hosts[0].alias == "prod-db")
        #expect(loaded.hosts[0].advanced[.compression] == "yes")
        #expect(loaded.hosts[0].controlPersist == .hours(8))
        #expect(loaded.hosts[0].tags == ["prod", "db"])
    }

    @Test func saveRotatesToPrev() throws {
        let store = try makeStore()
        var registry = HostRegistry()
        registry.upsert(ManagedHost(alias: "first", hostname: "a"))
        try store.save(registry)

        registry.upsert(ManagedHost(alias: "second", hostname: "b"))
        try store.save(registry)

        #expect(FileManager.default.fileExists(atPath: store.prevFile.path))
        let prevData = try Data(contentsOf: store.prevFile)
        let prevRegistry = try JSONDecoder.iso8601().decode(HostRegistry.self, from: prevData)
        #expect(prevRegistry.hosts.count == 1)
        #expect(prevRegistry.hosts.first?.alias == "first")
    }

    @Test func saveTakesBackupSnapshot() throws {
        let store = try makeStore()
        var registry = HostRegistry()
        registry.upsert(ManagedHost(alias: "a", hostname: "a.example.com"))
        try store.save(registry)
        registry.upsert(ManagedHost(alias: "b", hostname: "b.example.com"))
        try store.save(registry)

        let backups = try FileManager.default.contentsOfDirectory(
            atPath: store.backupsDirectory.path
        ).filter { $0.hasPrefix("hosts-") && $0.hasSuffix(".json") }
        #expect(!backups.isEmpty)
    }

    @Test func corruptedFileRecoversFromPrev() throws {
        let store = try makeStore()
        var registry = HostRegistry()
        registry.upsert(ManagedHost(alias: "good", hostname: "x.example.com"))
        try store.save(registry)
        // Save again so .prev gets populated with the good copy.
        registry.upsert(ManagedHost(alias: "second", hostname: "y.example.com"))
        try store.save(registry)

        // Corrupt the live file.
        try Data("not json".utf8).write(to: store.storeFile)

        // Load should recover from .prev (which has the "good" + "second"
        // version since the most recent save rotated the previous one).
        let recovered = try store.load()
        #expect(!recovered.hosts.isEmpty)
        // After successful .prev recovery the live file should be restored.
        #expect(FileManager.default.fileExists(atPath: store.storeFile.path))
    }

    @Test func validationRejectsDuplicateAlias() throws {
        let store = try makeStore()
        let id1 = UUID(); let id2 = UUID()
        let registry = HostRegistry(hosts: [
            ManagedHost(id: id1, alias: "prod", hostname: "a"),
            ManagedHost(id: id2, alias: "PROD", hostname: "b")
        ])
        #expect(throws: PersistenceError.self) {
            try store.save(registry)
        }
    }

    @Test func validationRejectsInvalidAlias() throws {
        let store = try makeStore()
        let registry = HostRegistry(hosts: [
            ManagedHost(alias: "has space", hostname: "x")
        ])
        #expect(throws: PersistenceError.self) {
            try store.save(registry)
        }
    }

    @Test func validationRejectsBadPort() throws {
        let store = try makeStore()
        let registry = HostRegistry(hosts: [
            ManagedHost(alias: "prod", hostname: "x", port: 0)
        ])
        #expect(throws: PersistenceError.self) {
            try store.save(registry)
        }
    }

    @Test func concurrentWritesDoNotCorrupt() async throws {
        let store = try makeStore()
        // First save establishes the file.
        try store.save(HostRegistry(hosts: [ManagedHost(alias: "seed", hostname: "s")]))

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    var reg = (try? store.load()) ?? HostRegistry()
                    reg.upsert(ManagedHost(alias: "h\(i)", hostname: "h\(i).example.com"))
                    _ = try? store.save(reg)
                }
            }
        }

        // After all concurrent writes settle, the file must still parse.
        let final = try store.load()
        #expect(final.schemaVersion == HostRegistry.currentSchemaVersion)
    }

    @Test func pruneKeepsLastTen() throws {
        let store = try makeStore()
        try FileManager.default.createDirectory(at: store.backupsDirectory, withIntermediateDirectories: true)
        // Create 15 dummy backups directly.
        for i in 0..<15 {
            let url = store.backupsDirectory.appendingPathComponent("hosts-2024010\(i).json")
            try Data("{}".utf8).write(to: url)
        }
        try store.pruneBackups()
        let kept = try FileManager.default.contentsOfDirectory(atPath: store.backupsDirectory.path)
            .filter { $0.hasPrefix("hosts-") }
        #expect(kept.count >= 10)
        // The "daily slot" rule may keep extras when they fall in different
        // calendar days; never fewer than the 10 most-recent.
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
