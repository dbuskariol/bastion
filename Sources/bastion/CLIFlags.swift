import Foundation
import BastionCore

/// Tiny POSIX-style flag parser for the CLI. Supports `--key value` and
/// `--key=value`; collects repeated flags into arrays. Single-letter
/// shorts aren't needed for this CLI surface.
struct CLIFlags {
    private(set) var positional: [String] = []
    private(set) var values: [String: [String]] = [:]
    private(set) var bools: Set<String> = []

    init(_ args: [String]) throws {
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("--") {
                let stripped = String(arg.dropFirst(2))
                if let eq = stripped.firstIndex(of: "=") {
                    let key = String(stripped[..<eq])
                    let value = String(stripped[stripped.index(after: eq)...])
                    values[key, default: []].append(value)
                } else {
                    let key = stripped
                    // Lookahead: if next token isn't a flag, treat as a value.
                    if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                        values[key, default: []].append(args[i + 1])
                        i += 1
                    } else {
                        bools.insert(key)
                    }
                }
            } else {
                positional.append(arg)
            }
            i += 1
        }
    }

    func first(_ key: String) -> String? { values[key]?.first }
    func all(_ key: String) -> [String] { values[key] ?? [] }
    func bool(_ key: String) -> Bool { bools.contains(key) }
    func requireFirst(_ key: String) throws -> String {
        guard let v = first(key) else { throw CLIError.missingFlag("--\(key)") }
        return v
    }
}

/// Parse a `--control-master` string.
func parseControlMaster(_ raw: String) throws -> ControlMasterChoice {
    switch raw.lowercased() {
    case "on", "auto", "yes":   return .on
    case "off", "no":           return .off
    case "inherit", "":         return .inherit
    default:
        throw CLIError.invalidValue(flag: "--control-master", value: raw,
                                    reason: "expected one of on / off / inherit")
    }
}

/// Parse a `--control-persist` string. Accepts the same forms ssh_config
/// does, plus 'inherit'.
func parseControlPersist(_ raw: String) throws -> ControlPersistChoice {
    let trimmed = raw.lowercased()
    switch trimmed {
    case "inherit", "":          return .inherit
    case "yes":                  return .indefinite
    case "no":                   return .disabled
    case "10m":                  return .minutes(10)
    case "30m":                  return .minutes(30)
    case "1h":                   return .hours(1)
    case "4h":                   return .hours(4)
    case "8h":                   return .hours(8)
    case "24h":                  return .hours(24)
    default:
        if trimmed.hasSuffix("h"), let n = Int(trimmed.dropLast()), n > 0 {
            return .hours(n)
        }
        if trimmed.hasSuffix("m"), let n = Int(trimmed.dropLast()), n > 0 {
            return .minutes(n)
        }
        throw CLIError.invalidValue(
            flag: "--control-persist", value: raw,
            reason: "expected 10m / 30m / 1h / 4h / 8h / 24h / yes / no / inherit"
        )
    }
}

/// Print JSON to stdout pretty-printed and sorted for reproducibility.
func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8) ?? "")
}
