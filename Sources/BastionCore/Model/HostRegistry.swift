import Foundation

/// Top-level registry: schema version + the list of every host Bastion
/// owns. Persisted as JSON at `Paths.hostsFile`. Forward-only migration.
public struct HostRegistry: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public var updatedAt: Date
    public var hosts: [ManagedHost]

    public static let currentSchemaVersion = 1

    public init(hosts: [ManagedHost] = [], updatedAt: Date = Date()) {
        self.schemaVersion = Self.currentSchemaVersion
        self.updatedAt = updatedAt
        self.hosts = hosts
    }

    public func host(named alias: String) -> ManagedHost? {
        let lowered = alias.lowercased()
        return hosts.first { $0.alias.lowercased() == lowered }
    }

    public func host(withID id: UUID) -> ManagedHost? {
        hosts.first { $0.id == id }
    }
}

public extension HostRegistry {
    /// Insert or update — keyed by `id`. Bumps `updatedAt`. The persistence
    /// layer enforces alias-uniqueness at write time.
    mutating func upsert(_ host: ManagedHost) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            var mutated = host
            mutated.updatedAt = Date()
            hosts[index] = mutated
        } else {
            hosts.append(host)
        }
        updatedAt = Date()
    }

    mutating func remove(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        updatedAt = Date()
    }

    /// True iff the alias is not in use by a different host.
    func aliasIsAvailable(_ alias: String, excluding excludedID: UUID? = nil) -> Bool {
        let lowered = alias.lowercased()
        return !hosts.contains { $0.alias.lowercased() == lowered && $0.id != excludedID }
    }
}
