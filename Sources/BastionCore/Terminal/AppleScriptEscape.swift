import Foundation

/// Single source of truth for escaping strings that get embedded into
/// AppleScript source we pass to /usr/bin/osascript. Rubber-duck N2:
/// every osascript invocation MUST funnel through this helper — no
/// ad-hoc string interpolation allowed.
///
/// AppleScript string literals follow C-like escape rules:
///   "  → \"
///   \  → \\
/// Plus we wrap the result in double quotes.
public enum AppleScriptEscape {
    /// Wrap a Swift string into a properly-escaped AppleScript string
    /// literal, including surrounding double quotes.
    public static func string(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)
        escaped.append("\"")
        for char in value {
            switch char {
            case "\\":
                escaped.append("\\\\")
            case "\"":
                escaped.append("\\\"")
            default:
                escaped.append(char)
            }
        }
        escaped.append("\"")
        return escaped
    }
}

/// Helpers for embedding a string into a percent-encoded URL component
/// (Warp, Tabby, Hyper schemes). Uses URLComponents semantics — same
/// behaviour as a browser's URL parser — so we never corrupt characters
/// that need encoding.
public enum URLEncode {
    public static func queryComponent(_ value: String) -> String {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "q", value: value)]
        // The percent-encoded form is everything after "q=".
        return components.percentEncodedQuery?
            .components(separatedBy: "q=").last ?? value
    }
}
