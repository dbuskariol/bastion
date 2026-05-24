import Foundation

/// Reads SSH certificate expiry via `ssh-keygen -L -f <cert>` and surfaces
/// a warning chip / notification when the cert is within the configured
/// window. Per consensus §15: warn at <7 days, notify at <48 hours
/// (one notification per cert per day).
public struct SSHCertExpiry: Sendable {
    public let pathResolver: PathResolver

    public init(pathResolver: PathResolver) {
        self.pathResolver = pathResolver
    }

    /// Returns the parsed cert validity end-time for the given identity
    /// file, if there's a matching `<key>-cert.pub` next to it. Returns
    /// nil for raw keys (no cert).
    public func validUntil(for identityFile: String) async -> Date? {
        let certPath = identityFile.hasSuffix(".pub")
            ? identityFile.replacingOccurrences(of: ".pub", with: "-cert.pub")
            : "\(identityFile)-cert.pub"
        guard FileManager.default.fileExists(atPath: certPath) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        proc.arguments = ["-L", "-f", certPath]
        proc.environment = pathResolver.environment()
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return nil }
        return Self.parseValidUntil(output)
    }

    /// Extract the `to ` date from ssh-keygen's `Valid: from … to …` line.
    /// Returns nil for `forever` certs (we don't notify on those).
    public static func parseValidUntil(_ output: String) -> Date? {
        // Line shape: "        Valid: from YYYY-MM-DDTHH:MM:SS to YYYY-MM-DDTHH:MM:SS"
        // Or:        "        Valid: forever"
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Valid:") else { continue }
            if trimmed.contains("forever") { return nil }
            if let toRange = trimmed.range(of: " to ") {
                let toPart = trimmed[toRange.upperBound...].trimmingCharacters(in: .whitespaces)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: toPart)
                    ?? Self.fallbackDateParse(String(toPart))
            }
        }
        return nil
    }

    private static func fallbackDateParse(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: raw)
    }

    /// Severity classification for the UI.
    public enum Severity: Sendable, Equatable {
        case ok
        case warningSoon  // <7 days
        case critical     // <48 hours
        case expired
    }

    public static func severity(validUntil: Date?, now: Date = Date()) -> Severity {
        guard let validUntil else { return .ok }
        let remaining = validUntil.timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        if remaining < 2 * 86_400 { return .critical }
        if remaining < 7 * 86_400 { return .warningSoon }
        return .ok
    }
}
