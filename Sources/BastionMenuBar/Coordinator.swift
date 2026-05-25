import Foundation
import SwiftUI
import Combine
import BastionCore
import BastionIdentifiers

/// Shared state for the host editor window. Owned by AppCoordinator
/// so opening the editor from anywhere (popover '+' button, host
/// context menu, expanded-card Edit) hands the draft into a single
/// Window scene that survives popover dismissal.
@MainActor
final class HostEditorState: ObservableObject {
    @Published var draft: ManagedHost = ManagedHost(alias: "new-host", hostname: "")
    @Published var originalAlias: String? = nil
    @Published var isReady: Bool = false
}

/// Single source-of-truth observable state for the menu app. Polls
/// `bastion status --json` via in-process ConnectionEngine; rolls up
/// selective polling cadences per the rubber-duck pass.
@MainActor
final class AppCoordinator: ObservableObject {

    @Published var status: StatusReport = StatusReport(appVersion: BastionVersion.value)
    @Published var lastMessage: String = "Loading…"
    @Published var defaultTerminal: TerminalID? = nil
    @Published var isRefreshing: Bool = false
    @Published var lastError: String? = nil

    /// Per dual-model consensus: bumped on every registry mutation
    /// (add / update / delete / import). `MenuContentView` attaches
    /// `.id(menuRevision)` to its root VStack so a registry change
    /// forces SwiftUI to discard the cached subtree (and any stale
    /// `MenuBarExtra(.window)` panel state) and mount fresh. NOT bumped
    /// on `refreshNow` polling ticks — only on user-initiated mutations
    /// — so scroll position and expanded-row state are preserved on
    /// periodic refreshes.
    @Published private(set) var menuRevision: Int = 0

    /// Per dual-model consensus: bumped before every `refreshNow()`
    /// invocation. Each Task captures the current generation; if a
    /// newer refresh has started before this one finishes, the older
    /// one's assignment to `self.status` is dropped. Fixes the race
    /// where a polling refresh started just before a host-add finishes
    /// after the save-triggered refresh and overwrites it.
    private var refreshGeneration: Int = 0

    /// Derived view-model the MenuBarExtra `label:` closure reads
    /// instead of `coordinator.status` directly. Equatable so we can
    /// guard re-publishes — most refreshes leave it unchanged.
    @Published private(set) var menuBarBadge: MenuBarBadge = .empty

    let engine = ConnectionEngine()
    let detector: TerminalDetector
    let factory = TerminalLauncherFactory()
    let preferences = MenuBarPreferences()
    let editorState = HostEditorState()

    private var refreshTask: Task<Void, Never>?
    private var popoverIsOpen: Bool = false
    private var pathWatcher: PathChangeWatcher?
    /// Track which hosts' masters are alive so we can detect transitions
    /// (alive → dead) and emit notifications.
    private var lastAliveHosts: Set<String> = []
    /// Per-host last-notification timestamps so we don't spam on flaps.
    private var notifiedAt: [String: Date] = [:]

    init() {
        self.detector = TerminalDetector(
            whichResolver: WhichResolver(pathResolver: engine.pathResolver)
        )
        self.defaultTerminal = preferences.defaultTerminal
            ?? detector.suggestedDefault()
        Task { await self.refreshNow() }
        startPolling()
        startPathWatcher()
    }

    deinit {
        refreshTask?.cancel()
    }

    private func startPathWatcher() {
        let watcher = PathChangeWatcher { [weak self] in
            await self?.refreshNow()
        }
        watcher.start()
        self.pathWatcher = watcher
    }

    // MARK: - Lifecycle

    func popoverDidOpen() {
        popoverIsOpen = true
        Task { await refreshNow() }
    }

    func popoverDidClose() {
        popoverIsOpen = false
    }

    // MARK: - Polling

    /// Per consensus + rubber-duck: selective cadence — up/establishing
    /// hosts polled fast (5s open / 30s closed), down hosts slow (60s
    /// open / 5min closed). We approximate by running one refresh per
    /// loop iteration; the engine.snapshot internally only spawns
    /// `ssh -O check` for hosts with ControlMaster enabled + usable
    /// ControlPath. Concurrency cap (max 8 in flight) lives in the
    /// snapshot method (TaskGroup with a semaphore).
    private func startPolling() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval: TimeInterval = (self?.popoverIsOpen ?? false) ? 5 : 30
                try? await Task.sleep(for: .seconds(interval))
                await self?.refreshNow()
            }
        }
    }

    @discardableResult
    func refreshNow() async -> StatusReport {
        // Race guard: capture our generation; drop our assignment if a
        // newer refreshNow() has started.
        refreshGeneration += 1
        let myGen = refreshGeneration

        isRefreshing = true
        defer { isRefreshing = false }
        let report = await engine.snapshot(appVersion: BastionVersion.value)

        // If a newer refresh started while we were snapshotting, drop
        // our result so the newer (or in-flight) one wins.
        guard myGen == refreshGeneration else { return report }

        await detectAndNotifyTransitions(newReport: report)
        let newBadge = MenuBarBadge(
            anyMasterAlive: report.hosts.contains { $0.controlMaster.status == .running },
            anyWarning: report.iCloudSyncSuspected || !report.includeInstalled
        )
        self.status = report
        self.lastMessage = "Updated \(Self.timeFormatter.string(from: report.generatedAt))"
        if newBadge != self.menuBarBadge {
            self.menuBarBadge = newBadge
        }

        // Refresh orphan detection. Only scan for hosts whose master is
        // NOT running — a running master means the `ssh -fNM` we'd
        // otherwise flag is the legitimate alive master. Scan happens
        // off the main actor (synchronous ps fork is ~5-20ms).
        let aliasesNeedingScan = report.hosts
            .filter { $0.controlMaster.status != .running }
            .map { $0.alias }
        if !aliasesNeedingScan.isEmpty {
            let scanned = await Task.detached { () -> [String: [OrphanReaper.Orphan]] in
                var byAlias: [String: [OrphanReaper.Orphan]] = [:]
                for alias in aliasesNeedingScan {
                    let found = OrphanReaper.scan(forAlias: alias)
                    if !found.isEmpty { byAlias[alias] = found }
                }
                return byAlias
            }.value
            self.orphansByAlias = scanned
        } else {
            self.orphansByAlias = [:]
        }

        // FIDO migration scan: hosts where requiresInteractiveAuth is
        // true but the REGISTRY-level controlMaster is not .on. The
        // predicate is registry-based (not effective-config based)
        // because the effective config can be temporarily OK if a stale
        // bastion.conf wasn't re-written yet — next save would erase
        // the ControlMaster line and break FIDO connect. We catch the
        // at-risk state, not just the actively-broken one.
        if !fidoMigrationAcked {
            // Cross-reference snapshot hosts with the underlying
            // registry (which carries `controlMaster: ControlMasterChoice`
            // — the snapshot only has the runtime ControlMasterState).
            let registry = (try? engine.loadRegistry())?.hosts ?? []
            let needsMigration = Set(
                registry
                    .filter { $0.requiresInteractiveAuth && $0.controlMaster != .on }
                    .map { $0.alias.lowercased() }
            )
            let candidates = report.hosts.filter { needsMigration.contains($0.alias.lowercased()) }
            self.fidoMigrationCandidates = candidates
            if !candidates.isEmpty && !fidoMigrationDialogPresented {
                fidoMigrationDialogPresented = true
            } else if candidates.isEmpty {
                fidoMigrationDialogPresented = false
            }
        }

        return report
    }

    /// Apply the consensus fix to all flagged FIDO hosts in one go:
    /// set ControlMaster=on, default ControlPersist if it was inherit.
    /// Route through `upsertHost` so the validator and writer run.
    func fidoMigrationFixAll() {
        Task {
            for candidate in fidoMigrationCandidates {
                guard var host = (try? engine.loadRegistry())?.host(named: candidate.alias) else { continue }
                host.controlMaster = .on
                if case .inherit = host.controlPersist {
                    host.controlPersist = .defaultChoice
                }
                _ = await upsertHost(host, skipIntegrationPass: true)
            }
            ackFidoMigration()
            await refreshNow()
        }
    }

    /// Write the ack marker so we don't re-present the dialog. Per-host
    /// editor warning still fires whenever the user opens that host.
    func ackFidoMigration() {
        try? Paths.ensureAppSupportDirectoryExists()
        // Ensure migrations subdir exists.
        let dir = Paths.fidoMigrationAckedMarker.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data().write(to: Paths.fidoMigrationAckedMarker, options: .atomic)
        fidoMigrationDialogPresented = false
    }

    /// User-initiated reap of orphaned `ssh -fNM <alias>` processes.
    /// Surfaced via the "Clean up N orphans" button in HostDetailCard.
    func reapOrphans(for alias: String) {
        let orphans = orphansByAlias[alias] ?? []
        guard !orphans.isEmpty else { return }
        Task {
            let result = await OrphanReaper.reap(
                alias: alias,
                pids: orphans.map(\.pid),
                engine: engine
            )
            if !result.pidsFailed.isEmpty {
                lastError = "Couldn't reap \(result.pidsFailed.count) orphan(s) — they may have already exited or escalated privileges."
            }
            await refreshNow()
        }
    }

    // MARK: - Coordinator-level mutation intents (dual-model fix)
    //
    // All view-driven registry mutations funnel through here so we can:
    //   1. bump `menuRevision` (forces `.id(...)`-based remount of the
    //      popover subtree — the deterministic kill for MenuBarExtra
    //      panel-cache staleness),
    //   2. centralise error surfacing into `lastError`,
    //   3. always refreshNow after a mutation,
    //   4. provide one diff-able log point for future bugs of this class.

    @discardableResult
    func upsertHost(_ host: ManagedHost, skipIntegrationPass: Bool = false) async -> ManagedConfigWriteResult? {
        do {
            let result = try await engine.upsertHost(host, skipIntegrationPass: skipIntegrationPass)
            menuRevision &+= 1
            await refreshNow()
            return result
        } catch {
            lastError = "Save failed: \(error)"
            return nil
        }
    }

    func deleteHost(_ alias: String) {
        Task {
            // Optimistic UI: rebuild the StatusReport using its own
            // initializer signature is brittle (every new field becomes
            // a silent break). Mutate the field directly instead — it's
            // a var on a struct, the struct lives in @Published var
            // status, so direct mutation triggers objectWillChange.
            var pruned = status
            pruned.hosts.removeAll { $0.alias.lowercased() == alias.lowercased() }
            self.status = pruned
            interactiveAuthStates.removeValue(forKey: alias)
            menuRevision &+= 1
            do {
                try await engine.removeHost(alias)
                await refreshNow()
            } catch {
                lastError = "Delete failed for \(alias): \(error)"
                // Re-fetch so the row reappears if delete actually failed.
                await refreshNow()
            }
        }
    }

    /// Inject the sentinel-guarded `Include` block into ~/.ssh/config
    /// and refresh status so the header warning chip disappears.
    func installSSHConfigInclude() {
        Task {
            do {
                _ = try engine.scanner.ensureIncludeInstalled()
                menuRevision &+= 1
                await refreshNow()
            } catch {
                lastError = "Couldn't install Include: \(error)"
            }
        }
    }

    /// Apply a batch of import candidates as managed hosts. Used by
    /// onboarding's import step and by `bastion import --apply`. Skips
    /// already-managed candidates by alias collision (case-insensitive).
    @discardableResult
    func applyImportCandidates(
        _ candidates: [ImportCandidate],
        controlMaster: ControlMasterChoice = .on,
        controlPersist: ControlPersistChoice = .inherit
    ) async -> (applied: Int, skipped: Int) {
        var applied = 0
        var skipped = 0
        for candidate in candidates where !candidate.alreadyManaged {
            let host = ManagedHost(
                alias: candidate.suggestedAlias,
                hostname: candidate.hostname,
                user: candidate.user,
                port: candidate.port,
                identityFiles: candidate.identityFiles,
                controlMaster: controlMaster,
                controlPersist: controlPersist
            )
            do {
                _ = try await engine.upsertHost(host, skipIntegrationPass: true)
                applied += 1
            } catch {
                skipped += 1
                lastError = "Skipped \(candidate.suggestedAlias): \(error)"
            }
        }
        if applied > 0 {
            menuRevision &+= 1
            await refreshNow()
        }
        return (applied, skipped)
    }

    /// Compare the new report against `lastAliveHosts` and dispatch
    /// notifications for masters that flipped from alive → dead while
    /// inside ControlPersist. Coalesces with `notifiedAt` so a flapping
    /// network doesn't spam Notification Centre.
    private func detectAndNotifyTransitions(newReport: StatusReport) async {
        guard preferences.notifyOnMasterDrop else {
            lastAliveHosts = Set(newReport.hosts.filter { $0.controlMaster.status == .running }.map { $0.alias })
            return
        }
        let alive = Set(newReport.hosts.filter { $0.controlMaster.status == .running }.map { $0.alias })
        let dropped = lastAliveHosts.subtracting(alive)
        let now = Date()
        for alias in dropped {
            if let last = notifiedAt[alias], now.timeIntervalSince(last) < 60 { continue }
            notifiedAt[alias] = now
            await NotificationDispatcher.shared.post(
                category: .masterDropped,
                host: alias,
                body: "The ControlMaster for \(alias) dropped unexpectedly."
            )
        }
        lastAliveHosts = alive
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()

    // MARK: - Actions

    func openHostEditor(for alias: String? = nil) {
        if let alias {
            let registry = (try? engine.loadRegistry()) ?? HostRegistry()
            if let existing = registry.host(named: alias) {
                editorState.draft = existing
                editorState.originalAlias = existing.alias
            } else {
                editorState.draft = ManagedHost(alias: "new-host", hostname: "")
                editorState.originalAlias = nil
            }
        } else {
            editorState.draft = ManagedHost(alias: "new-host", hostname: "")
            editorState.originalAlias = nil
        }
        editorState.isReady = true
    }

    func setDefaultTerminal(_ id: TerminalID) {
        preferences.defaultTerminal = id
        self.defaultTerminal = id
    }

    /// Per-host auth state for interactive (FIDO/SSO) bootstrap UX.
    /// `notRequired` for plain key-auth hosts.
    enum InteractiveAuthState: Equatable {
        case notRequired                        // not a FIDO host
        case authenticating(since: Date)        // user is doing the FIDO dance
        case ready                              // master alive, ready to multiplex
        case failed(String)                     // timeout or error
    }

    @Published var interactiveAuthStates: [String: InteractiveAuthState] = [:]

    /// Orphans detected per alias on the most recent scan. Refreshed by
    /// `refreshNow()`. UI surfaces a "Clean up N orphans" chip in the
    /// detail card when count > 0 AND master is not running for that
    /// alias.
    @Published var orphansByAlias: [String: [OrphanReaper.Orphan]] = [:]

    /// Hosts surfaced in the one-time FIDO migration dialog: those
    /// where `requiresInteractiveAuth==true` but ControlMaster isn't
    /// effective (so connect would fail). Predicate is computed on
    /// every snapshot; the dialog presents iff this is non-empty AND
    /// the user hasn't already acked or fixed.
    @Published var fidoMigrationCandidates: [HostSnapshot] = []
    @Published var fidoMigrationDialogPresented: Bool = false

    /// True once the acked marker file exists. Read fresh on every
    /// refresh — file-truth, not @State cache — so dismissing/writing
    /// the marker takes effect immediately on next render. Per
    /// rubber-duck #11 to avoid the cache-bug class re-emerging on the
    /// new dialog.
    var fidoMigrationAcked: Bool {
        FileManager.default.fileExists(atPath: Paths.fidoMigrationAckedMarker.path)
    }

    /// Derived auth state for the row chip. Combines the in-memory
    /// transient state (`.authenticating`, `.failed`) with snapshot-
    /// derived state (`.ready` when host requires FIDO AND master is
    /// running). The `.ready` state is derived rather than stored so it
    /// survives app restart for hosts whose master is still alive.
    func authState(for host: HostSnapshot) -> InteractiveAuthState {
        if let stored = interactiveAuthStates[host.alias] {
            switch stored {
            case .authenticating, .failed:
                return stored
            case .notRequired, .ready:
                break  // fall through to derived
            }
        }
        if host.requiresInteractiveAuth && host.controlMaster.status == .running {
            return .ready
        }
        return .notRequired
    }

    func connect(_ alias: String, newWindow: Bool = false) {
        Task {
            await connectImpl(alias, newWindow: newWindow)
        }
    }

    private func connectImpl(_ alias: String, newWindow: Bool) async {
        // Re-entrancy guard: if a previous connect is mid-flight for
        // this alias (chip is .authenticating and the FIDO touch hasn't
        // hit the 180s timeout yet), no-op. Prevents the two-orphaned-
        // PIDs bug visible in the user's debug output.
        if case .authenticating(let since) = interactiveAuthStates[alias],
           Date().timeIntervalSince(since) < 180 {
            return
        }

        guard let terminalID = defaultTerminal else {
            lastError = "No default terminal set. Open Preferences to pick one."
            return
        }
        let launcher = factory.launcher(for: terminalID)
        let env = engine.pathResolver.environment()

        let host = (try? engine.loadRegistry())?.host(named: alias)

        // Pre-flight: resolve effective config with a 500ms timeout (so
        // CanonicalizeHostname/Match-exec hangs can't lock the UI).
        // This MUST come before the optimistic chip flip so we never
        // briefly lie about state. The probe is local-only on a sane
        // config — well under the 100ms human-perception threshold.
        let preflight: EffectiveConfig? = await engine.reader
            .effectiveConfigWithTimeout(forAlias: alias, timeout: 0.5)

        if host?.requiresInteractiveAuth == true {
            // FIDO host MUST have a master configured. The model-layer
            // validator catches this at save time, but a pre-existing
            // host with .inherit may have slipped through; we double-
            // check at connect time.
            if let pf = preflight,
               !(pf.controlMasterEnabled && pf.usableControlPath != nil) {
                interactiveAuthStates[alias] = .failed(
                    "ControlMaster not configured for this FIDO host — open the editor and switch ControlMaster to On."
                )
                lastError = "FIDO host \(alias) needs ControlMaster=On. Open the editor."
                return
            }
        }

        // Fast path 1: master already alive → multiplex into a shell.
        let state = (try? await engine.checkMaster(alias))
                    ?? ControlMasterState(status: .unknown)
        if state.status == .running {
            if host?.requiresInteractiveAuth == true {
                interactiveAuthStates[alias] = .ready
            }
            launch(launcher: launcher, argv: ["ssh", alias], newWindow: newWindow, env: env)
            return
        }

        // Fast path 2: try BatchMode bootstrap. If cached creds in agent
        // (1Password, ssh-agent, passkey) work, we authenticate silently
        // and skip the FIDO touch entirely — matching `gh auth login`'s
        // "try cached cred first" UX. Hard 2s timeout with subprocess
        // kill protects against TCP slowness.
        //
        // For FIDO hosts: flip optimistic .authenticating only AFTER
        // the BatchMode attempt — otherwise the chip flickers even when
        // the silent path succeeds.
        if state.enabled {
            if let bg = await engine.establishBackgroundMasterWithTimeout(alias, timeout: 2.0),
               bg.exitCode == 0 {
                // Background master came up. Mark ready (if FIDO) and shell in.
                if host?.requiresInteractiveAuth == true {
                    interactiveAuthStates[alias] = .ready
                }
                launch(launcher: launcher, argv: ["ssh", alias], newWindow: newWindow, env: env)
                await refreshNow()
                return
            }
        }

        // Bootstrap fallback paths.
        if host?.requiresInteractiveAuth == true {
            // FIDO bootstrap: launch foreground `ssh -fNM` for the
            // FIDO touch, then poll for the master.
            interactiveAuthStates[alias] = .authenticating(since: Date())
            launch(
                launcher: launcher,
                argv: ["ssh", "-fNM",
                       "-o", "ServerAliveInterval=60",
                       "-o", "ServerAliveCountMax=3",
                       alias],
                newWindow: false,
                env: env
            )
            let outcome = await engine.awaitMaster(alias, timeout: 180)
            switch outcome {
            case .alive:
                interactiveAuthStates[alias] = .ready
                await NotificationDispatcher.shared.post(
                    category: .masterDropped,
                    host: alias,
                    body: "Authentication complete. Opening shell…"
                )
                launch(launcher: launcher, argv: ["ssh", alias], newWindow: true, env: env)
                await refreshNow()
            case .timeout:
                interactiveAuthStates[alias] = .failed("Authentication didn't complete in 3 minutes.")
                await NotificationDispatcher.shared.post(
                    category: .masterDropped,
                    host: alias,
                    body: "Authentication timed out. Click Connect to retry."
                )
            case .staleAfterHeal(let socket):
                interactiveAuthStates[alias] = .failed("Stale socket at \(socket) couldn't be cleared automatically. Try `ssh -O exit \(alias)` or remove the socket file manually.")
            case .preflightFailed(let reason):
                interactiveAuthStates[alias] = .failed("Master configuration broken: \(reason). Open the editor.")
            }
            return
        }

        // Non-FIDO fallback: open the terminal so the user can handle
        // any prompts visibly (password, passphrase, host-key trust).
        launch(launcher: launcher, argv: ["ssh", alias], newWindow: newWindow, env: env)
    }

    /// "Unlock for the day" — pre-warm the ControlMaster without
    /// auto-opening a shell. The user clicks this once in the morning;
    /// every subsequent Connect is instant for the rest of the
    /// ControlPersist window.
    func unlockMaster(_ alias: String) {
        // Re-entrancy guard: same logic as connect.
        if case .authenticating(let since) = interactiveAuthStates[alias],
           Date().timeIntervalSince(since) < 180 {
            return
        }
        // Optimistic flip — by the time we get here we've decided to do
        // real work (no fast paths to short-circuit through).
        interactiveAuthStates[alias] = .authenticating(since: Date())
        Task {
            await unlockMasterImpl(alias)
        }
    }

    private func unlockMasterImpl(_ alias: String) async {
        guard let terminalID = defaultTerminal else {
            lastError = "No default terminal set."
            interactiveAuthStates.removeValue(forKey: alias)
            return
        }
        let launcher = factory.launcher(for: terminalID)
        let env = engine.pathResolver.environment()

        // Try BatchMode fast-path first (cached creds via agent or
        // passkey). Skip foreground launch if it succeeds.
        if let bg = await engine.establishBackgroundMasterWithTimeout(alias, timeout: 2.0),
           bg.exitCode == 0 {
            interactiveAuthStates[alias] = .ready
            let host = (try? engine.loadRegistry())?.host(named: alias)
            let persistLabel = host.map { Self.formatPersist($0.controlPersist) } ?? "the persist window"
            await NotificationDispatcher.shared.post(
                category: .masterDropped, host: alias,
                body: "Authenticated. Connects will be instant for \(persistLabel)."
            )
            await refreshNow()
            return
        }

        launch(
            launcher: launcher,
            argv: ["ssh", "-fNM",
                   "-o", "ServerAliveInterval=60",
                   "-o", "ServerAliveCountMax=3",
                   alias],
            newWindow: false,
            env: env
        )
        let outcome = await engine.awaitMaster(alias, timeout: 180)
        switch outcome {
        case .alive:
            interactiveAuthStates[alias] = .ready
            let host = (try? engine.loadRegistry())?.host(named: alias)
            let persistLabel = host.map { Self.formatPersist($0.controlPersist) } ?? "the persist window"
            await NotificationDispatcher.shared.post(
                category: .masterDropped, host: alias,
                body: "Authenticated. Connects will be instant for \(persistLabel)."
            )
            await refreshNow()
        case .timeout:
            interactiveAuthStates[alias] = .failed("Auth didn't complete in 3 minutes.")
        case .staleAfterHeal(let socket):
            interactiveAuthStates[alias] = .failed("Stale socket at \(socket) couldn't be cleared automatically.")
        case .preflightFailed(let reason):
            interactiveAuthStates[alias] = .failed("Master not configured: \(reason).")
        }
    }

    /// Human-readable rendering of `ControlPersistChoice` for chips and
    /// notification bodies. Replaces the previous hardcoded "~8h".
    private static func formatPersist(_ choice: ControlPersistChoice) -> String {
        switch choice {
        case .inherit:        return "the persist window"
        case .minutes(let m): return "\(m) minute\(m == 1 ? "" : "s")"
        case .hours(let h):   return "\(h) hour\(h == 1 ? "" : "s")"
        case .indefinite:     return "the session"
        case .disabled:       return "this connection only"
        }
    }

    private func launch(launcher: TerminalLauncher, argv: [String], newWindow: Bool, env: [String: String]) {
        do {
            try launcher.launch(argv: argv, newWindow: newWindow, environment: env)
            lastError = nil
        } catch let error as TerminalLaunchError {
            lastError = error.description
        } catch {
            lastError = error.localizedDescription
        }
    }

    func disconnectMaster(_ alias: String) {
        Task {
            _ = try? await engine.stopMaster(alias)
            await refreshNow()
        }
    }

    func copyConnectCommand(_ alias: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("ssh \(alias)", forType: .string)
    }

    func openSSHConfig() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-t", Paths.userSSHConfig.path]
        try? proc.run()
    }

    func openManagedConfig() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-t", Paths.managedConfigFile.path]
        try? proc.run()
    }
}

// MARK: - Menu-bar-only preferences store

/// Tiny derived view-model of the only things the MenuBarExtra `label:`
/// closure needs to read. Equatable so we can guard re-publishes.
struct MenuBarBadge: Equatable, Sendable {
    var anyMasterAlive: Bool
    var anyWarning: Bool
    static let empty = MenuBarBadge(anyMasterAlive: false, anyWarning: false)
}

/// Simple wrapper around UserDefaults + preferences.json for the menu
/// app's per-process preferences. The CLI's PreferencesStore uses the
/// same on-disk file; this class keeps a published copy in memory for
/// SwiftUI.
@MainActor
final class MenuBarPreferences: ObservableObject {
    @Published var defaultTerminal: TerminalID? {
        didSet { persist() }
    }
    @Published var notifyOnMasterDrop: Bool = false { didSet { persist() } }
    @Published var notifyOnCertExpiry: Bool = false { didSet { persist() } }
    @Published var notifyOnPersistExpiry: Bool = false { didSet { persist() } }
    @Published var allowRemoteInfoFetch: Bool = false { didSet { persist() } }

    private struct Payload: Codable {
        var schemaVersion: Int
        var defaultTerminal: TerminalID?
        var notifyOnMasterDrop: Bool
        var notifyOnCertExpiry: Bool
        var notifyOnPersistExpiry: Bool
        var allowRemoteInfoFetch: Bool
    }

    init() {
        if FileManager.default.fileExists(atPath: Paths.preferencesFile.path),
           let data = try? Data(contentsOf: Paths.preferencesFile),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            self.defaultTerminal = payload.defaultTerminal
            self.notifyOnMasterDrop = payload.notifyOnMasterDrop
            self.notifyOnCertExpiry = payload.notifyOnCertExpiry
            self.notifyOnPersistExpiry = payload.notifyOnPersistExpiry
            self.allowRemoteInfoFetch = payload.allowRemoteInfoFetch
        }
    }

    private func persist() {
        try? Paths.ensureAppSupportDirectoryExists()
        let payload = Payload(
            schemaVersion: 1,
            defaultTerminal: defaultTerminal,
            notifyOnMasterDrop: notifyOnMasterDrop,
            notifyOnCertExpiry: notifyOnCertExpiry,
            notifyOnPersistExpiry: notifyOnPersistExpiry,
            allowRemoteInfoFetch: allowRemoteInfoFetch
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(payload) {
            try? data.write(to: Paths.preferencesFile, options: .atomic)
        }
    }
}
