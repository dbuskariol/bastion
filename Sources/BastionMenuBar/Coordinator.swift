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
        return report
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
        controlMaster: ControlMasterChoice = .inherit,
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

    func connect(_ alias: String, newWindow: Bool = false) {
        // Optimistic UI: if the host needs interactive auth, flip the
        // chip to `.authenticating` synchronously so the user sees
        // immediate feedback. (Without this, the chip didn't change
        // until after the multi-hundred-ms `ssh -O check` returned.)
        if let host = (try? engine.loadRegistry())?.host(named: alias),
           host.requiresInteractiveAuth {
            interactiveAuthStates[alias] = .authenticating(since: Date())
        }
        Task {
            guard let terminalID = defaultTerminal else {
                lastError = "No default terminal set. Open Preferences to pick one."
                interactiveAuthStates.removeValue(forKey: alias)
                return
            }
            let launcher = factory.launcher(for: terminalID)
            let env = engine.pathResolver.environment()

            // Fast path: master alive → multiplex straight into a shell.
            // This is the "every connect after the first" UX — instant.
            let state = (try? await engine.checkMaster(alias))
                        ?? ControlMasterState(status: .unknown)
            if state.status == .running {
                interactiveAuthStates[alias] = .ready
                launch(launcher: launcher, argv: ["ssh", alias], newWindow: newWindow, env: env)
                return
            }

            // Resolve the managed host to decide bootstrap strategy.
            let host = (try? engine.loadRegistry())?.host(named: alias)

            // FIDO / interactive-auth path: open a foreground `ssh -fNM`
            // tab so the user can complete the auth dance in their
            // terminal. Then poll for the master coming up and
            // auto-open the shell tab. Per dual-model consensus we
            // never automate the auth touch or the Enter keystroke.
            if host?.requiresInteractiveAuth == true {
                // (Already set to .authenticating above for instant UI.)
                launch(
                    launcher: launcher,
                    argv: ["ssh", "-fNM",
                           "-o", "ServerAliveInterval=60",
                           "-o", "ServerAliveCountMax=3",
                           alias],
                    newWindow: false,
                    env: env
                )
                let alive = await engine.awaitMaster(alias, timeout: 180)
                if alive {
                    interactiveAuthStates[alias] = .ready
                    await NotificationDispatcher.shared.post(
                        category: .masterDropped,  // reuse opt-in category
                        host: alias,
                        body: "Authentication complete. Opening shell…"
                    )
                    launch(launcher: launcher, argv: ["ssh", alias], newWindow: true, env: env)
                    await refreshNow()
                } else {
                    interactiveAuthStates[alias] = .failed("Authentication didn't complete in 3 minutes.")
                    await NotificationDispatcher.shared.post(
                        category: .masterDropped,
                        host: alias,
                        body: "Authentication timed out. Click Connect to retry."
                    )
                }
                return
            }

            // Default (non-interactive) path: optimistic BatchMode
            // bootstrap; on failure, open the user's terminal with `ssh
            // <alias>` so they can handle any prompts visibly.
            if state.enabled {
                if let bgResult = try? await engine.establishBackgroundMaster(alias),
                   bgResult.exitCode == 0 {
                    // Master came up silently — fast-launch the shell.
                    launch(launcher: launcher, argv: ["ssh", alias], newWindow: newWindow, env: env)
                    await refreshNow()
                    return
                }
            }
            // Final fallback: just open the terminal with `ssh <alias>`.
            launch(launcher: launcher, argv: ["ssh", alias], newWindow: newWindow, env: env)
        }
    }

    /// "Unlock for the day" — pre-warm the ControlMaster without
    /// auto-opening a shell. The user clicks this once in the morning;
    /// every subsequent Connect is instant for the rest of the
    /// ControlPersist window.
    func unlockMaster(_ alias: String) {
        // Optimistic synchronous flip so the chip changes immediately.
        interactiveAuthStates[alias] = .authenticating(since: Date())
        Task {
            guard let terminalID = defaultTerminal else {
                lastError = "No default terminal set."
                interactiveAuthStates.removeValue(forKey: alias)
                return
            }
            let launcher = factory.launcher(for: terminalID)
            let env = engine.pathResolver.environment()
            launch(
                launcher: launcher,
                argv: ["ssh", "-fNM",
                       "-o", "ServerAliveInterval=60",
                       "-o", "ServerAliveCountMax=3",
                       alias],
                newWindow: false,
                env: env
            )
            let alive = await engine.awaitMaster(alias, timeout: 180)
            if alive {
                interactiveAuthStates[alias] = .ready
                await NotificationDispatcher.shared.post(
                    category: .masterDropped, host: alias,
                    body: "Authenticated. Connects will be instant for the next ~8h."
                )
                await refreshNow()
            } else {
                interactiveAuthStates[alias] = .failed("Auth didn't complete in 3 minutes.")
            }
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
