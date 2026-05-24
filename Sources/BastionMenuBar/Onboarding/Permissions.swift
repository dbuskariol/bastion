import Foundation
import SwiftUI
import ServiceManagement
import UserNotifications
import BastionIdentifiers

/// Wraps `SMAppService.mainApp` for the Open-at-Login toggle. Hard-guards
/// `register()` on the bundle being at `/Applications/Bastion.app` and
/// not translocated — `register()` records the bundle URL with launchd,
/// so registering from anywhere else bakes a path that disappears.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered

    init() { refresh() }

    var isEnabled: Bool { status == .enabled }

    var statusDescription: String {
        switch status {
        case .notRegistered:    return "Not enabled"
        case .enabled:          return "Enabled"
        case .requiresApproval: return "Requires approval in System Settings"
        case .notFound:         return "App not registered with launchd"
        @unknown default:       return "Unknown"
        }
    }

    var canRegisterFromHere: Bool {
        !BastionIdentifiers.isTranslocated
            && Bundle.main.bundlePath == "/Applications/Bastion.app"
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    enum SetEnabledResult { case ok, requiresMove, requiresApproval, failed(Error) }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> SetEnabledResult {
        if enabled && !canRegisterFromHere {
            return .requiresMove
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            return status == .requiresApproval ? .requiresApproval : .ok
        } catch {
            refresh()
            return .failed(error)
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Wraps UNUserNotificationCenter authorisation for the per-host
/// notification toggles. Strictly opt-in — `requestAuthorization` is
/// never called unless the user explicitly turns notifications on
/// (matches Vigil's stance).
@MainActor
final class NotificationPermission: ObservableObject {
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined

    init() {
        Task { await refresh() }
    }

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run { self.status = settings.authorizationStatus }
    }

    /// Request authorisation. Caller must only call this when the user
    /// explicitly opts in.
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            await refresh()
            return granted
        } catch {
            await refresh()
            return false
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}
