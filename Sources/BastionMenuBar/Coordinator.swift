import Foundation
import SwiftUI
import Combine
import BastionCore
import BastionIdentifiers

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

    private var refreshTask: Task<Void, Never>?
    private var popoverIsOpen: Bool = false

    init() {
        self.detector = TerminalDetector(
            whichResolver: WhichResolver(pathResolver: engine.pathResolver)
        )
        self.defaultTerminal = preferences.defaultTerminal
            ?? detector.suggestedDefault()
        Task { await self.refreshNow() }
        startPolling()
    }

    deinit {
        refreshTask?.cancel()
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
        self.status = report
        self.lastMessage = "Updated \(Self.timeFormatter.string(from: report.generatedAt))"
        return report
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()

    // MARK: - Actions

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
