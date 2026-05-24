import Foundation

/// Per-shell parsers + the top-level ImportEngine that ties everything
/// together. Privacy invariant: history file contents stay in memory
/// only — no parsed history is persisted to disk anywhere in Bastion.

/// Bash history reader. Plain mode is one command per line. With
/// `HISTTIMEFORMAT` set the file alternates `#<epoch>` lines with
/// commands. We sniff per-pair to support both.
public struct BashHistoryParser: Sendable {
    public init() {}
    public func extractLines(from text: String) -> [(line: String, lineNo: Int, timestamp: Date?)] {
        var out: [(String, Int, Date?)] = []
        var pendingStamp: Date? = nil
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            if line.hasPrefix("#"), let epoch = TimeInterval(line.dropFirst()) {
                pendingStamp = Date(timeIntervalSince1970: epoch)
                continue
            }
            if !line.isEmpty {
                out.append((line, index + 1, pendingStamp))
                pendingStamp = nil
            }
        }
        return out
    }
}

/// Zsh history reader. Supports extended-history format
/// `: <epoch>:<duration>;<cmd>` and plain (sniffed per-line).
public struct ZshHistoryParser: Sendable {
    public init() {}
    public func extractLines(from text: String) -> [(line: String, lineNo: Int, timestamp: Date?)] {
        var out: [(String, Int, Date?)] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            if line.isEmpty { continue }
            if line.hasPrefix(": ") {
                // : <epoch>:<duration>;<cmd>
                if let semi = line.firstIndex(of: ";") {
                    let header = line[line.index(line.startIndex, offsetBy: 2)..<semi]
                    let parts = header.split(separator: ":")
                    let stamp: Date? = parts.first.flatMap { TimeInterval(String($0)) }.map { Date(timeIntervalSince1970: $0) }
                    let cmd = String(line[line.index(after: semi)...])
                    out.append((cmd, index + 1, stamp))
                    continue
                }
            }
            out.append((line, index + 1, nil))
        }
        return out
    }
}

/// Fish history reader. The YAML-ish format used by fish 2.x and 3.x:
///   - cmd: ssh foo
///     when: 1234567890
/// We do a minimal hand-rolled parser (no YAML dep).
public struct FishHistoryParser: Sendable {
    public init() {}
    public func extractLines(from text: String) -> [(line: String, lineNo: Int, timestamp: Date?)] {
        var out: [(String, Int, Date?)] = []
        var currentCmd: String?
        var currentWhen: Date?
        var startLine = 0
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            if line.hasPrefix("- cmd:") {
                if let cmd = currentCmd {
                    out.append((cmd, startLine, currentWhen))
                }
                currentCmd = String(line.dropFirst("- cmd:".count)).trimmingCharacters(in: .whitespaces)
                currentWhen = nil
                startLine = index + 1
            } else if line.contains("when:") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let n = TimeInterval(trimmed.replacingOccurrences(of: "when:", with: "").trimmingCharacters(in: .whitespaces)) {
                    currentWhen = Date(timeIntervalSince1970: n)
                }
            }
        }
        if let cmd = currentCmd {
            out.append((cmd, startLine, currentWhen))
        }
        return out
    }
}

/// Parser for ~/.ssh/known_hosts. Skips hashed entries (we can't recover
/// hostnames from them). Returns synthetic ParsedConnections with no user.
public struct KnownHostsParser: Sendable {
    public init() {}
    public func extract(from text: String, source: HistorySource = .knownHosts(lineNumber: 0)) -> [ParsedConnection] {
        var out: [ParsedConnection] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // First field is the hostnames-or-hash list. Skip hashed.
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let firstField = parts.first else { continue }
            let hostsField = String(firstField)
            if hostsField.hasPrefix("|") { continue }                       // hashed
            if hostsField.hasPrefix("@cert-authority") { continue }
            if hostsField.hasPrefix("@revoked") { continue }
            // Multiple comma-separated host/IP entries.
            for entry in hostsField.split(separator: ",") {
                var host = String(entry)
                var port = 22
                // Bracketed [host]:port form.
                if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
                    let inner = String(host[host.index(after: host.startIndex)..<close])
                    let after = host[host.index(after: close)...]
                    if after.hasPrefix(":") {
                        port = Int(after.dropFirst()) ?? 22
                    }
                    host = inner
                }
                // Skip ip-only entries (we don't know what name they belong to).
                // Pragmatic: still surface, the user can edit alias.
                out.append(ParsedConnection(
                    user: nil, hostname: host, port: port,
                    source: .knownHosts(lineNumber: index + 1)
                ))
            }
        }
        return out
    }
}
