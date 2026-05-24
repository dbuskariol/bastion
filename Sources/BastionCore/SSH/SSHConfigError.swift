import Foundation

/// Errors raised by the SSH-config writer/scanner/reader trio. All
/// errors carry enough context for the UI to surface a useful message.
public enum SSHConfigError: Error, CustomStringConvertible, Equatable {
    case invalidAlias(String)
    case invalidValue(option: String, reason: String)
    case validationFailed(stderr: String)
    case io(String)
    case unsafeUserConfig(reason: String)

    public var description: String {
        switch self {
        case .invalidAlias(let a):              return "invalid alias: \(a)"
        case .invalidValue(let opt, let r):     return "invalid value for \(opt): \(r)"
        case .validationFailed(let s):          return "ssh -G validation failed:\n\(s)"
        case .io(let s):                        return "I/O error: \(s)"
        case .unsafeUserConfig(let r):          return r
        }
    }
}
