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
    @Published var lastConnectError: String? = nil

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
        isRefreshing = true
        defer { isRefreshing = false }
        let report = await engine.snapshot(appVersion: BastionVersion.value)
        await detectAndNotifyTransitions(newReport: report)
        self.status = report
        self.lastMessage = "Updated \(Self.timeFormatter.string(from: report.generatedAt))"
        return report
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

    func connect(_ alias: String, newWindow: Bool = false) {
        Task {
            do {
                guard let terminalID = defaultTerminal else {
                    lastConnectError = "No default terminal set. Open Preferences to pick one."
                    return
                }
                let launcher = factory.launcher(for: terminalID)
                try launcher.launch(
                    argv: ["ssh", alias],
                    newWindow: newWindow,
                    environment: engine.pathResolver.environment()
                )
                lastConnectError = nil
            } catch let error as TerminalLaunchError {
                lastConnectError = error.description
            } catch {
                lastConnectError = error.localizedDescription
            }
        }
    }

    func disconnectMaster(_ alias: String) {
        Task {
            _ = try? await engine.stopMaster(alias)
            await refreshNow()
        }
    }

    func deleteHost(_ alias: String) {
        Task {
            do {
                try await engine.removeHost(alias)
                await refreshNow()
            } catch {
                lastConnectError = "Delete failed: \(error)"
            }
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

    /// Inject the sentinel-guarded `Include` block into ~/.ssh/config and
    /// refresh status so the header warning chip disappears.
    func installSSHConfigInclude() {
        Task {
            do {
                _ = try engine.scanner.ensureIncludeInstalled()
                await refreshNow()
            } catch {
                lastConnectError = "Couldn't install Include: \(error)"
            }
        }
    }
}

// MARK: - Menu-bar-only preferences store

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
