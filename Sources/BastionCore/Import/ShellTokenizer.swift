import Foundation

/// A POSIX-shell-style tokenizer. Handles single + double quotes,
/// backslash escapes, and common env-var prefixes like
/// `FOO=bar ssh host`. NOT a full shell parser — we intentionally do
/// not expand variables or follow command substitutions; for those we
/// skip the line because we can't safely interpret it.
public struct ShellTokenizer {
    public init() {}

    public enum TokenError: Error, Equatable {
        case unterminatedQuote
        case unsafeSubstitution    // $(...) / `...` — refuse to interpret
        case empty
    }

    public func tokenize(_ line: String) throws -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { throw TokenError.empty }
        // Refuse lines with command substitution — we'd have to execute
        // arbitrary code to know what they reference.
        if trimmed.contains("$(") || trimmed.contains("`") {
            throw TokenError.unsafeSubstitution
        }

        var tokens: [String] = []
        var current = ""
        var i = trimmed.startIndex
        var inSingle = false
        var inDouble = false

        while i < trimmed.endIndex {
            let c = trimmed[i]
            switch c {
            case "\\":
                let next = trimmed.index(after: i)
                guard next < trimmed.endIndex else {
                    current.append(c)
                    i = next
                    continue
                }
                current.append(trimmed[next])
                i = trimmed.index(after: next)
            case "'":
                if inDouble {
                    current.append(c)
                } else {
                    inSingle.toggle()
                }
                i = trimmed.index(after: i)
            case "\"":
                if inSingle {
                    current.append(c)
                } else {
                    inDouble.toggle()
                }
                i = trimmed.index(after: i)
            case " ", "\t":
                if inSingle || inDouble {
                    current.append(c)
                } else if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                i = trimmed.index(after: i)
            default:
                current.append(c)
                i = trimmed.index(after: i)
            }
        }
        if inSingle || inDouble { throw TokenError.unterminatedQuote }
        if !current.isEmpty { tokens.append(current) }

        // Strip leading env-var assignments like FOO=bar.
        while let first = tokens.first,
              let eq = first.firstIndex(of: "="),
              first[..<eq].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            tokens.removeFirst()
        }
        return tokens
    }
}

/// Parses a `[user@]host[:port]` token into components. Handles bracketed
/// IPv6 `[::1]:22` form.
public enum HostTokenParser {
    public static func parse(_ token: String) -> (user: String?, host: String, port: Int?)? {
        var rest = token
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        // Bracketed IPv6: [::1]:22
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            let host = String(rest[rest.index(after: rest.startIndex)..<close])
            let afterBracket = rest[rest.index(after: close)...]
            var port: Int?
            if afterBracket.hasPrefix(":") {
                port = Int(afterBracket.dropFirst())
            }
            return (user, host, port)
        }
        // host[:port] — but NOT for git-style `host:path/repo.git` (path
        // contains `/`). We treat trailing-colon-with-digits as port.
        if let colon = rest.lastIndex(of: ":") {
            let after = rest[rest.index(after: colon)...]
            if let port = Int(after) {
                return (user, String(rest[..<colon]), port)
            }
        }
        return (user, rest, nil)
    }
}

/// Common extractor protocol — each implementation is `func extract(...) -> [ParsedConnection]`.
public protocol CommandExtractor: Sendable {
    func extract(argv: [String], source: HistorySource, timestamp: Date?) -> [ParsedConnection]
}
