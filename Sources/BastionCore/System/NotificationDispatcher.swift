import Foundation
import UserNotifications
import Network
import BastionIdentifiers

/// Categories for the per-host notification toggles. The user enables
/// each category in Preferences; each category is opt-in default-off.
public enum NotificationCategory: String, Sendable, CaseIterable {
    case masterDropped       = "bastion.master-dropped"
    case masterReady         = "bastion.master-ready"
    case persistExpired      = "bastion.persist-expired"
    case keepaliveFailure    = "bastion.keepalive-failure"
    case agentForgotKey      = "bastion.agent-forgot-key"
    case externalConfigEdit  = "bastion.external-config-edit"
    case certExpiringSoon    = "bastion.cert-expiring-soon"

    public var displayTitle: String {
        switch self {
        case .masterDropped:       return "Authentication expired"
        case .masterReady:         return "Authenticated"
        case .persistExpired:      return "ControlPersist expired"
        case .keepaliveFailure:    return "Connection unresponsive"
        case .agentForgotKey:      return "Keychain locked"
        case .externalConfigEdit:  return "SSH config changed"
        case .certExpiringSoon:    return "SSH cert expiring soon"
        }
    }
}

/// Dispatches user notifications. Coalesces per-host events via
/// `threadIdentifier` so a flaky network doesn't spam Notification
/// Centre.
@MainActor
public final class NotificationDispatcher {
    public static let shared = NotificationDispatcher()
    private init() {}

    public func post(category: NotificationCategory, host: String, body: String, action: String? = nil) async {
        // Don't dispatch unless the user has explicitly granted
        // authorisation (handled by NotificationPermission).
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "\(category.displayTitle) — \(host)"
        content.body = body
        content.sound = .default
        // Per-host coalescing thread.
        content.threadIdentifier = "bastion.host.\(host)"
        if let action {
            content.userInfo = ["action": action]
        }
        let request = UNNotificationRequest(
            identifier: "\(category.rawValue).\(host).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Watches NWPathMonitor for VPN drop / Wi-Fi reconnects so we can
/// re-check master sockets after a network blip. Per consensus + rubber-
/// duck: we do NOT auto-disconnect on path-down — OpenSSH's keepalives
/// handle slow degradation gracefully; brief network blips recover
/// without action. We just refresh and surface notifications for masters
/// that died.
@MainActor
public final class PathChangeWatcher {
    public let onPathUp: () async -> Void
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.bastion.path-monitor")
    private var lastSatisfied: Bool = false
    private var started = false

    public init(onPathUp: @escaping () async -> Void) {
        self.onPathUp = onPathUp
    }

    public func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let satisfied = path.status == .satisfied
                if satisfied && !self.lastSatisfied {
                    await self.onPathUp()
                }
                self.lastSatisfied = satisfied
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
