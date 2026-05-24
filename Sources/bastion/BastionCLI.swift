import Foundation
import BastionCore
import BastionIdentifiers

/// CLI entrypoint. Dispatches verbs to ConnectionEngine. JSON output is
/// the machine-readable contract the menu app polls; human output is the
/// default for interactive use.
@main
struct BastionCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let exitCode: Int32

        do {
            exitCode = try await dispatch(args)
        } catch let error as CLIError {
            FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
            exitCode = error.exitCode
        } catch let error as CustomStringConvertible {
            FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
            exitCode = 1
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exitCode = 1
        }
        exit(exitCode)
    }

    private static func dispatch(_ args: [String]) async throws -> Int32 {
        guard let verb = args.first else {
            printUsage()
            return 0
        }

        switch verb {
        case "--version", "version":
            print(BastionVersion.value)
            return 0
        case "--help", "-h", "help":
            printUsage(); return 0
        case "list":
            return try await runList(rest(args))
        case "show":
            return try await runShow(rest(args))
        case "add":
            return try await runAdd(rest(args))
        case "edit":
            return try await runEdit(rest(args))
        case "remove", "rm":
            return try await runRemove(rest(args))
        case "connect":
            return try await runConnect(rest(args))
        case "master":
            return try await runMaster(rest(args))
        case "terminal":
            return try await runTerminal(rest(args))
        case "status":
            return try await runStatus(rest(args))
        case "config":
            return try await runConfig(rest(args))
        case "import":
            return try await runImport(rest(args))
        case "uninstall":
            return try await runUninstall(rest(args))
        default:
            throw CLIError.unknown(verb: verb)
        }
    }

    private static func rest(_ args: [String]) -> [String] { Array(args.dropFirst()) }

    private static func printUsage() {
        print("""
        bastion: manage SSH connections from one place.

        Usage:
          bastion list [--json]
          bastion show <alias> [--json]
          bastion add <alias> --host <hostname> [--user <u>] [--port <p>]
                             [--identity <path>]... [--control-master {on|off|inherit}]
                             [--control-persist {10m|30m|1h|4h|8h|24h|yes|no|inherit}]
                             [--tag <tag>]... [--note <text>]
          bastion edit <alias> [same flags as add]
          bastion remove <alias>
          bastion connect <alias> [--print-only]
          bastion master start|stop|check <alias> [--json]
          bastion terminal list [--json]
          bastion terminal set <id>
          bastion status [--json]
          bastion config doctor [--json]
          bastion config sync
          bastion config install-include
          bastion config remove-include
          bastion import <source> [--apply] [--json] [--sort {recent|most-used|alphabetical}]
                  source = zsh|bash|fish|known-hosts|ssh-config|all
          bastion uninstall [--keep-keys]
        """)
    }
}

// MARK: - Errors

enum CLIError: Error, CustomStringConvertible {
    case unknown(verb: String)
    case missingFlag(String)
    case invalidValue(flag: String, value: String, reason: String)
    case engine(EngineError)
    case io(String)

    var description: String {
        switch self {
        case .unknown(let v):                    return "unknown verb: \(v) (try `bastion --help`)"
        case .missingFlag(let f):                return "missing required flag: \(f)"
        case .invalidValue(let f, let v, let r): return "invalid value for \(f): \(v.debugDescription) — \(r)"
        case .engine(let e):                     return e.description
        case .io(let s):                         return "I/O: \(s)"
        }
    }
    var exitCode: Int32 {
        switch self {
        case .unknown, .missingFlag, .invalidValue: return 64
        case .engine, .io:                          return 1
        }
    }
}
