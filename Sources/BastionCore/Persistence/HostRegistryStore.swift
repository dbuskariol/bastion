import Foundation

/// Errors produced by the persistence layer.
public enum PersistenceError: Error, CustomStringConvertible, Equatable {
    /// `hosts.json` exists but cannot be decoded into a known schema
    /// version. The store will attempt `.prev` recovery before surfacing.
    case corrupted(String)
    /// The store wrote successfully but the post-write sanity read failed.
    /// Should be vanishingly rare; surfaced for diagnostics.
    case roundTripMismatch
    /// We rejected a registry that violated invariants (duplicate alias,
    /// invalid alias characters) — caller must fix and retry.
    case validationFailed(String)
    /// Underlying I/O error (file not writable, etc.).
    case io(String)

    public var description: String {
        switch self {
        case .corrupted(let s):          return "corrupted hosts.json: \(s)"
        case .roundTripMismatch:         return "post-write read mismatched written data"
        case .validationFailed(let s):   return "validation failed: \(s)"
        case .io(let s):                 return "I/O error: \(s)"
        }
    }
}

/// Reads + writes `hosts.json` and its rotating backups. Atomic write
/// semantics: temp → fsync → rename. Validates the registry before
/// writing and rolls back to `.prev` if a post-write read fails.
public final class HostRegistryStore: @unchecked Sendable {
    public let storeFile: URL
    public let prevFile: URL
    public let backupsDirectory: URL

    private let fileManager: FileManager
    private let writeLock = NSLock()
    private let clock: () -> Date

    public init(
        storeFile: URL = Paths.hostsFile,
        prevFile: URL = Paths.hostsPrevFile,
        backupsDirectory: URL = Paths.backupsDirectory,
        fileManager: FileManager = .default,
        clock: @escaping () -> Date = Date.init
    ) {
        self.storeFile = storeFile
        self.prevFile = prevFile
        self.backupsDirectory = backupsDirectory
        self.fileManager = fileManager
        self.clock = clock
    }

    /// Load the registry. If `hosts.json` is missing, returns an empty
    /// registry (first run). If it's corrupted, tries `.prev` then fails
    /// loud — never silently returns empty when the file existed.
    public func load() throws -> HostRegistry {
        writeLock.lock()
        defer { writeLock.unlock() }

        if !fileManager.fileExists(atPath: storeFile.path) {
            return HostRegistry()
        }
        do {
            return try decode(url: storeFile)
        } catch let primary as PersistenceError {
            if fileManager.fileExists(atPath: prevFile.path),
               let recovered = try? decode(url: prevFile) {
                // Restore from .prev so subsequent saves don't keep losing data.
                try? fileManager.removeItem(at: storeFile)
                try? fileManager.copyItem(at: prevFile, to: storeFile)
                return recovered
            }
            throw primary
        } catch {
            throw PersistenceError.corrupted(error.localizedDescription)
        }
    }

    /// Atomically write the registry. Validates first, takes a backup of
    /// the previous version, writes to a tempfile, fsyncs, renames, then
    /// re-reads to confirm round-trip integrity. On round-trip failure the
    /// previous version is restored from the backup.
    public func save(_ registry: HostRegistry) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

        try validate(registry)
        try Paths.ensureAppSupportDirectoryExists()

        // Rotate: current → .prev, plus take a timestamped backup.
        if fileManager.fileExists(atPath: storeFile.path) {
            try? fileManager.removeItem(at: prevFile)
            try? fileManager.copyItem(at: storeFile, to: prevFile)
            try snapshotBackup()
            try pruneBackups()
        }

        let payload = try encoded(registry)

        let temp = storeFile.appendingPathExtension("tmp")
        try? fileManager.removeItem(at: temp)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else {
            throw PersistenceError.io("cannot open \(temp.path) for write")
        }
        defer { close(fd) }
        try payload.withUnsafeBytes { bytes in
            let bp = bytes.bindMemory(to: UInt8.self)
            var written = 0
            while written < bytes.count {
                let n = Darwin.write(fd, bp.baseAddress!.advanced(by: written), bytes.count - written)
                if n < 0 {
                    throw PersistenceError.io("write failed: \(String(cString: strerror(errno)))")
                }
                written += n
            }
        }
        guard fsync(fd) == 0 else {
            throw PersistenceError.io("fsync failed: \(String(cString: strerror(errno))))")
        }
        guard rename(temp.path, storeFile.path) == 0 else {
            throw PersistenceError.io("rename failed: \(String(cString: strerror(errno))))")
        }

        // Round-trip read-back. Verifies integrity: we can decode what we
        // just wrote into a registry whose hosts match by id. We don't
        // strict-equal because JSONEncoder's .iso8601 strategy truncates
        // sub-second precision; the in-memory Date and the decoded Date
        // are coherent but not byte-equal.
        do {
            let reread = try decode(url: storeFile)
            if reread.schemaVersion != registry.schemaVersion
                || Set(reread.hosts.map(\.id)) != Set(registry.hosts.map(\.id)) {
                try? fileManager.removeItem(at: storeFile)
                if fileManager.fileExists(atPath: prevFile.path) {
                    try? fileManager.copyItem(at: prevFile, to: storeFile)
                }
                throw PersistenceError.roundTripMismatch
            }
        } catch let pe as PersistenceError {
            throw pe
        } catch {
            throw PersistenceError.roundTripMismatch
        }
    }

    /// True iff there is at least one persisted host. Used by onboarding
    /// to decide whether to show "Import hosts" or "Done" defaults.
    public func isEmpty() -> Bool {
        (try? load().hosts.isEmpty) ?? true
    }

    // MARK: - Backups (GFS rotation: last 10, plus one per day for 7 days)

    /// Take a snapshot copy of the current `hosts.json` into
    /// `backups/hosts-YYYYMMDD-HHMMSS.json`. Called inside `save` before
    /// the new contents replace the existing file.
    public func snapshotBackup() throws {
        guard fileManager.fileExists(atPath: storeFile.path) else { return }
        try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let stamp = Self.timestampFormatter.string(from: clock())
        let dest = backupsDirectory.appendingPathComponent("hosts-\(stamp).json")
        try? fileManager.removeItem(at: dest)
        try fileManager.copyItem(at: storeFile, to: dest)
    }

    /// Keep last 10 backups plus one per day for the last 7 days
    /// (Grandfather-Father-Son). Per the rubber-duck pass: bursty edits
    /// can rotate the last-10 set out within a minute, so daily slots
    /// protect against same-day churn.
    public func pruneBackups() throws {
        guard fileManager.fileExists(atPath: backupsDirectory.path) else { return }
        let entries = try fileManager.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasPrefix("hosts-") && $0.pathExtension == "json" }

        let sorted = entries.sorted { lhs, rhs in
            (lhs.creationDate ?? Date.distantPast) > (rhs.creationDate ?? Date.distantPast)
        }

        let keepRecent = Set(sorted.prefix(10))

        // Daily-slot keepers: youngest backup per calendar day, for last 7 days.
        var perDay: [String: URL] = [:]
        let now = clock()
        let day = TimeInterval(86_400)
        let cutoff = now.addingTimeInterval(-7 * day)
        for url in sorted {
            guard let created = url.creationDate, created >= cutoff else { continue }
            let key = Self.dayKey(for: created)
            if perDay[key] == nil { perDay[key] = url }
        }
        let keepDaily = Set(perDay.values)

        let keep = keepRecent.union(keepDaily)
        for url in entries where !keep.contains(url) {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Internal helpers

    private func encoded(_ registry: HostRegistry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(registry)
        } catch {
            throw PersistenceError.io("encode: \(error.localizedDescription)")
        }
    }

    private func decode(url: URL) throws -> HostRegistry {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PersistenceError.io("read \(url.path): \(error.localizedDescription)")
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(HostRegistry.self, from: data)
        } catch {
            throw PersistenceError.corrupted(error.localizedDescription)
        }
    }

    private func validate(_ registry: HostRegistry) throws {
        var seen: Set<String> = []
        for host in registry.hosts {
            guard Alias.isValid(host.alias) else {
                throw PersistenceError.validationFailed(
                    "invalid alias \(host.alias.debugDescription) (must match \(Alias.pattern))"
                )
            }
            let lowered = host.alias.lowercased()
            if seen.contains(lowered) {
                throw PersistenceError.validationFailed("duplicate alias: \(host.alias)")
            }
            seen.insert(lowered)
            if host.port < 1 || host.port > 65535 {
                throw PersistenceError.validationFailed(
                    "host \(host.alias): port \(host.port) out of range"
                )
            }
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static func dayKey(for date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }
}

// MARK: - URL creation-date convenience

private extension URL {
    var creationDate: Date? {
        (try? resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}
