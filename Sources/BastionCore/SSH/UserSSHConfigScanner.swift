import Foundation

/// Result of scanning the user's `~/.ssh/config` for things Bastion needs
/// to know before it does anything to the file.
public struct UserSSHConfigScan: Sendable, Equatable {
    /// True iff our sentinel-guarded `Include ~/.ssh/config.d/*.conf`
    /// block is already present.
    public let sentinelInstalled: Bool
    /// Any `Host` aliases the user already defines (across the top-level
    /// file only — we don't follow nested Include here; that's `ssh -G`'s
    /// job). Used by the import flow to mark candidates as "already external".
    public let existingHostAliases: [String]
    /// True iff the user has any `Include` directive that already covers
    /// `~/.ssh/config.d/*.conf` (i.e. we don't need to inject ours).
    public let coveringIncludePresent: Bool
    /// True iff there is at least one `Match exec` block. Per rubber-duck
    /// pass B4: `ssh -G` invocations evaluate `Match exec` so we warn
    /// the user before triggering it as part of post-write validation.
    public let hasMatchExec: Bool
    /// True iff the file is empty / didn't exist.
    public let isEmpty: Bool
    /// If `~/.ssh/config` is itself a symlink (chezmoi, dotbot, 1Password
    /// backup), this carries the resolved target. Per rubber-duck B1.
    public let resolvedSymlinkTarget: URL?

    /// Per-block view of every `Host` / `Match host` stanza that sets
    /// any of `ControlPath`, `ControlMaster`, or `ControlPersist`.
    /// Powers the cross-name-variant shared-master conflict warnings —
    /// the Coordinator filters this list against each managed
    /// `host.hostname` to surface "Your ~/.ssh/config will override
    /// Bastion's ControlPath" warnings in the editor. Per dual-model
    /// consensus + rubber-duck on the shared-master design.
    public let controlPathDeclarations: [ControlPathDeclaration]

    /// True iff the FIRST `ControlPath`-setting directive in the file
    /// appears BEFORE our `Include` block. When false, Bastion's
    /// ControlPath is at risk of being shadowed for FQDN-typed
    /// connections by an earlier user wildcard. Per rubber-duck N1 +
    /// the dual-model consensus' wildcard-precedence risk #1.
    public let bastionIncludeIsFirst: Bool

    public init(
        sentinelInstalled: Bool,
        existingHostAliases: [String],
        coveringIncludePresent: Bool,
        hasMatchExec: Bool,
        isEmpty: Bool,
        resolvedSymlinkTarget: URL?,
        controlPathDeclarations: [ControlPathDeclaration] = [],
        bastionIncludeIsFirst: Bool = true
    ) {
        self.sentinelInstalled = sentinelInstalled
        self.existingHostAliases = existingHostAliases
        self.coveringIncludePresent = coveringIncludePresent
        self.hasMatchExec = hasMatchExec
        self.isEmpty = isEmpty
        self.resolvedSymlinkTarget = resolvedSymlinkTarget
        self.controlPathDeclarations = controlPathDeclarations
        self.bastionIncludeIsFirst = bastionIncludeIsFirst
    }
}

/// One `Host` or `Match host` stanza in the user's config that sets
/// at least one of the multiplex directives (ControlPath / ControlMaster
/// / ControlPersist). Used to detect collisions with Bastion's managed
/// hostnames.
public struct ControlPathDeclaration: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case hostBlock      // `Host pattern1 pattern2 ...`
        case matchHost      // `Match host pattern1,pattern2,...`
    }
    public let kind: Kind
    /// Whitespace- (or comma-, for Match-host) separated list of
    /// patterns as the user wrote them. May contain wildcards.
    public let patterns: [String]
    /// Line number in the original file where the stanza header appears.
    public let lineNumber: Int
    /// Whether this block is BEFORE Bastion's `Include` (so its
    /// directives win for any matching host typed on the CLI). When
    /// false, Bastion's bastion.conf is processed first and wins.
    public let isBeforeBastionInclude: Bool
    /// Did the block contain a `ControlPath` line?
    public let setsControlPath: Bool
    /// Did the block contain `ControlMaster` (any value)?
    public let setsControlMaster: Bool
    /// Did the block contain `ControlPersist` (any value)?
    public let setsControlPersist: Bool

    /// True if any of the block's patterns matches `hostname` per
    /// OpenSSH's glob semantics (`*` = any char, `?` = one char,
    /// case-insensitive). Naive impl, sufficient for warning purposes.
    public func matches(hostname: String) -> Bool {
        let target = hostname.lowercased()
        for pattern in patterns {
            if Self.glob(pattern.lowercased(), target) { return true }
        }
        return false
    }

    /// `ssh_config(5)` pattern matching subset: `*` matches zero or
    /// more chars, `?` matches exactly one. Negation (`!pat`) is
    /// supported in stanzas as "if any negation matches, the stanza
    /// doesn't apply" — but for the warning use case we conservatively
    /// treat negations as non-matches (no false alarm).
    private static func glob(_ pattern: String, _ target: String) -> Bool {
        if pattern.hasPrefix("!") { return false }
        // Translate ssh glob → NSRegularExpression.
        var rx = "^"
        for ch in pattern {
            switch ch {
            case "*": rx.append(".*")
            case "?": rx.append(".")
            case ".", "(", ")", "+", "|", "^", "$", "[", "]", "\\", "{", "}":
                rx.append("\\")
                rx.append(ch)
            default: rx.append(ch)
            }
        }
        rx.append("$")
        return target.range(of: rx, options: [.regularExpression]) != nil
    }
}

/// Side effects from an `Include`-injection run.
public enum IncludeInstallOutcome: Sendable, Equatable {
    case alreadyPresent
    case injected
    case noopBecauseUserHasCoveringInclude
}

/// Scans + mutates `~/.ssh/config` minimally:
/// - Reads the top-level file to detect existing `Host` aliases, our
///   sentinel block, any covering `Include`, and `Match exec` presence.
/// - Injects our 3-line sentinel-guarded `Include ~/.ssh/config.d/*.conf`
///   at the very top of the file (so per-alias precedence works).
/// - Removes our sentinel block on uninstall, preserving everything else.
///
/// This scanner is intentionally tiny: it never interprets values, never
/// follows `Include`, never parses `Match exec` predicates. `ssh -G` does
/// all the heavy lifting for effective-config reads.
public struct UserSSHConfigScanner {
    public let configFile: URL
    private let fileManager: FileManager

    public init(configFile: URL = Paths.userSSHConfig, fileManager: FileManager = .default) {
        self.configFile = configFile
        self.fileManager = fileManager
    }

    // MARK: - Scan

    public func scan() throws -> UserSSHConfigScan {
        let symlinkTarget = try Self.resolveIfSymlink(configFile, fileManager: fileManager)
        let inspectionURL = symlinkTarget ?? configFile

        guard fileManager.fileExists(atPath: inspectionURL.path) else {
            return UserSSHConfigScan(
                sentinelInstalled: false,
                existingHostAliases: [],
                coveringIncludePresent: false,
                hasMatchExec: false,
                isEmpty: true,
                resolvedSymlinkTarget: symlinkTarget
            )
        }

        let raw: String
        do {
            raw = try String(contentsOf: inspectionURL, encoding: .utf8)
        } catch {
            throw SSHConfigError.io("read \(inspectionURL.path): \(error.localizedDescription)")
        }

        var sentinelInstalled = false
        var coveringIncludePresent = false
        var hasMatchExec = false
        var aliases: [String] = []
        var declarations: [ControlPathDeclaration] = []

        // Per-stanza tracking. We accumulate directives between Host/
        // Match headers and emit one ControlPathDeclaration per stanza
        // that touches any of the multiplex directives.
        var currentBlock: (kind: ControlPathDeclaration.Kind, patterns: [String], lineNumber: Int, isBeforeInclude: Bool)?
        var currentSetsControlPath = false
        var currentSetsControlMaster = false
        var currentSetsControlPersist = false

        // Track whether we've encountered Bastion's Include (or a
        // covering Include) yet. Once we have, subsequent stanzas
        // come AFTER our config — they don't shadow us.
        var bastionIncludeSeen = false

        func flushCurrentBlock() {
            if let block = currentBlock,
               currentSetsControlPath || currentSetsControlMaster || currentSetsControlPersist {
                declarations.append(ControlPathDeclaration(
                    kind: block.kind,
                    patterns: block.patterns,
                    lineNumber: block.lineNumber,
                    isBeforeBastionInclude: block.isBeforeInclude,
                    setsControlPath: currentSetsControlPath,
                    setsControlMaster: currentSetsControlMaster,
                    setsControlPersist: currentSetsControlPersist
                ))
            }
            currentBlock = nil
            currentSetsControlPath = false
            currentSetsControlMaster = false
            currentSetsControlPersist = false
        }

        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        for (idx, rawLine) in lines {
            let lineNumber = idx + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed == Paths.includeBlockBegin {
                sentinelInstalled = true
                bastionIncludeSeen = true
                continue
            }
            if trimmed.hasPrefix("#") { continue }
            if trimmed.isEmpty { continue }

            let lower = trimmed.lowercased()
            if lower.hasPrefix("include ") || lower.hasPrefix("include\t") || lower == "include" {
                var rest = String(trimmed.dropFirst("include".count))
                rest = rest.trimmingCharacters(in: .whitespaces)
                if includeMatchesOurGlob(rest) {
                    coveringIncludePresent = true
                    bastionIncludeSeen = true
                }
            } else if lower.hasPrefix("host ") || lower.hasPrefix("host\t") {
                flushCurrentBlock()
                let rest = String(trimmed.dropFirst("host".count))
                let names = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                for name in names where name != "*" {
                    if Alias.isValid(name) { aliases.append(name) }
                }
                currentBlock = (kind: .hostBlock, patterns: names,
                                lineNumber: lineNumber,
                                isBeforeInclude: !bastionIncludeSeen)
            } else if lower.hasPrefix("match ") || lower.hasPrefix("match\t") {
                flushCurrentBlock()
                let rest = String(trimmed.dropFirst("match".count)).trimmingCharacters(in: .whitespaces)
                let restLower = rest.lowercased()
                if restLower.contains("exec ") || restLower.contains("exec\t") || restLower.contains("exec\"") {
                    hasMatchExec = true
                }
                // Parse `Match host pat1,pat2 [user x] [...]` — we only
                // care about the `host` criterion for collision detection.
                if let patterns = Self.extractMatchHostPatterns(rest) {
                    currentBlock = (kind: .matchHost, patterns: patterns,
                                    lineNumber: lineNumber,
                                    isBeforeInclude: !bastionIncludeSeen)
                }
            } else if currentBlock != nil {
                // We're inside a Host/Match stanza. Look for the three
                // multiplex directives.
                if lower.hasPrefix("controlpath") { currentSetsControlPath = true }
                else if lower.hasPrefix("controlmaster") { currentSetsControlMaster = true }
                else if lower.hasPrefix("controlpersist") { currentSetsControlPersist = true }
            }
        }
        flushCurrentBlock()

        // Bastion include is "first" iff we have our sentinel AND no
        // earlier stanza set a ControlPath directive. (We don't worry
        // about the "no sentinel but covering include later" case —
        // that's just "no Bastion config yet".)
        let bastionIncludeIsFirst = !declarations.contains { decl in
            decl.isBeforeBastionInclude && decl.setsControlPath
        }

        return UserSSHConfigScan(
            sentinelInstalled: sentinelInstalled,
            existingHostAliases: aliases,
            coveringIncludePresent: coveringIncludePresent,
            hasMatchExec: hasMatchExec,
            isEmpty: false,
            resolvedSymlinkTarget: symlinkTarget,
            controlPathDeclarations: declarations,
            bastionIncludeIsFirst: bastionIncludeIsFirst
        )
    }

    /// Parse the criteria of a `Match` line and return the host
    /// pattern(s) if the `host` criterion is present. Returns nil for
    /// `Match all` / `Match originalhost`/`Match user`/etc. without
    /// `host`. Handles comma-separated host lists.
    static func extractMatchHostPatterns(_ rest: String) -> [String]? {
        // Tokenise on whitespace; walk looking for `host` followed by
        // the next non-keyword token.
        let tokens = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var i = 0
        while i < tokens.count {
            let key = tokens[i].lowercased()
            if key == "host" || key == "originalhost" {
                if i + 1 < tokens.count {
                    let list = tokens[i + 1]
                    return list.split(separator: ",").map { String($0) }
                }
                return nil
            }
            // Skip known one-arg criteria.
            if key == "user" || key == "localuser" || key == "exec" || key == "address" {
                i += 2; continue
            }
            // Skip zero-arg criteria.
            if key == "all" || key == "canonical" || key == "final" || key == "tagged" {
                i += 1; continue
            }
            i += 1
        }
        return nil
    }

    // MARK: - Install / uninstall the sentinel-guarded Include

    /// Install the 3-line sentinel-guarded `Include` block at the very
    /// top of `~/.ssh/config`. Idempotent: returns `.alreadyPresent` if
    /// our sentinel is detected, `.noopBecauseUserHasCoveringInclude` if
    /// the user already has an `Include` that covers our path.
    public func ensureIncludeInstalled() throws -> IncludeInstallOutcome {
        try ensureSSHDirectoryExists()
        let symlinkTarget = try Self.resolveIfSymlink(configFile, fileManager: fileManager)
        let targetURL = symlinkTarget ?? configFile

        let existing: String
        if fileManager.fileExists(atPath: targetURL.path) {
            do {
                existing = try String(contentsOf: targetURL, encoding: .utf8)
            } catch {
                throw SSHConfigError.io("read \(targetURL.path): \(error.localizedDescription)")
            }
        } else {
            existing = ""
        }

        let scan = try scan()
        if scan.sentinelInstalled { return .alreadyPresent }
        if scan.coveringIncludePresent { return .noopBecauseUserHasCoveringInclude }

        let header = [
            "\(Paths.includeBlockBegin) — do not edit. Remove the whole block to uninstall Bastion.",
            Paths.includeDirective,
            Paths.includeBlockEnd
        ].joined(separator: "\n")

        let new: String
        if existing.isEmpty {
            new = header + "\n"
        } else {
            new = header + "\n\n" + existing
        }
        try atomicWrite(content: new, to: targetURL, mode: 0o600)
        return .injected
    }

    /// Strip our sentinel block from `~/.ssh/config`. Preserves
    /// everything outside the block byte-for-byte. Safe to call when
    /// sentinel is absent (returns false).
    @discardableResult
    public func removeInclude() throws -> Bool {
        let symlinkTarget = try Self.resolveIfSymlink(configFile, fileManager: fileManager)
        let targetURL = symlinkTarget ?? configFile

        guard fileManager.fileExists(atPath: targetURL.path) else { return false }
        let existing: String
        do {
            existing = try String(contentsOf: targetURL, encoding: .utf8)
        } catch {
            throw SSHConfigError.io("read \(targetURL.path): \(error.localizedDescription)")
        }
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
        var output: [Substring] = []
        var inBlock = false
        var removed = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inBlock, trimmed.hasPrefix(Paths.includeBlockBegin) {
                inBlock = true; removed = true; continue
            }
            if inBlock, trimmed == Paths.includeBlockEnd {
                inBlock = false; continue
            }
            if inBlock { continue }
            output.append(line)
        }
        // Trim a leading blank-line we may have left behind from inserting
        // header + blank-separator above.
        while let first = output.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            output.removeFirst()
        }
        let new = output.joined(separator: "\n")
        try atomicWrite(content: new, to: targetURL, mode: 0o600)
        return removed
    }

    // MARK: - Helpers

    private func includeMatchesOurGlob(_ rest: String) -> Bool {
        // Normalise: strip quotes, expand leading ~.
        var s = rest
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        let expanded = NSString(string: s).expandingTildeInPath
        let oursExpanded = NSString(string: "~/.ssh/config.d/*.conf").expandingTildeInPath
        // Two acceptable shapes: literal match of our directive (with or
        // without tilde) or a broader pattern that covers our directory.
        if expanded == oursExpanded { return true }
        let bastionConfPath = NSString(string: "~/.ssh/config.d/bastion.conf").expandingTildeInPath
        // Trivial coverage check: directory prefix + .conf suffix.
        let ourDir = (oursExpanded as NSString).deletingLastPathComponent
        if expanded.hasPrefix(ourDir + "/") && expanded.hasSuffix("*.conf") {
            return true
        }
        if expanded == bastionConfPath { return true }
        return false
    }

    private func ensureSSHDirectoryExists() throws {
        do {
            try fileManager.createDirectory(
                at: Paths.userSSHDirectory,
                withIntermediateDirectories: true,
                attributes: [FileAttributeKey.posixPermissions: 0o700]
            )
        } catch {
            throw SSHConfigError.io("mkdir ~/.ssh: \(error.localizedDescription)")
        }
    }

    private func atomicWrite(content: String, to target: URL, mode: mode_t) throws {
        let temp = target.appendingPathExtension("tmp")
        try? fileManager.removeItem(at: temp)
        let data = Data(content.utf8)
        do {
            try data.write(to: temp, options: .atomic)
            try fileManager.setAttributes(
                [FileAttributeKey.posixPermissions: NSNumber(value: mode)],
                ofItemAtPath: temp.path
            )
        } catch {
            throw SSHConfigError.io("write \(temp.path): \(error.localizedDescription)")
        }
        // Use rename(2) explicitly so we don't trip Darwin's
        // FileManager.replaceItem follow-symlink behaviour (rubber-duck B1:
        // if target is a symlink we've already resolved it above; use the
        // resolved path here too).
        guard rename(temp.path, target.path) == 0 else {
            throw SSHConfigError.io("rename failed: \(String(cString: strerror(errno)))")
        }
    }

    /// Rubber-duck B1: if `~/.ssh/config` is a symlink (chezmoi, dotbot,
    /// 1Password backup, GNU Stow), atomic write through the symlink
    /// path replaces the symlink with a regular file and silently severs
    /// the user's dotfile manager. We resolve to the link target so all
    /// reads + writes go through that, preserving the link.
    public static func resolveIfSymlink(_ url: URL, fileManager: FileManager) throws -> URL? {
        var statbuf = stat()
        guard lstat(url.path, &statbuf) == 0 else { return nil }
        guard (statbuf.st_mode & S_IFMT) == S_IFLNK else { return nil }
        do {
            let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            if target.hasPrefix("/") {
                return URL(fileURLWithPath: target)
            }
            // Relative symlink: resolve against the link's directory.
            let parent = url.deletingLastPathComponent()
            return parent.appendingPathComponent(target)
        } catch {
            throw SSHConfigError.io("readlink \(url.path): \(error.localizedDescription)")
        }
    }
}
