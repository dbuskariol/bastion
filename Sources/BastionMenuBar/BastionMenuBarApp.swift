import SwiftUI
import AppKit
import BastionCore
import BastionIdentifiers

@main
struct BastionMenuBarApp: App {
    // AppDelegate owns the menu-bar surface (NSStatusItem + NSPopover)
    // AND the coordinator/updateController. We deliberately do NOT
    // hold `@StateObject` references at App scope — those subscribe
    // the App's body to the underlying ObservableObject, which on
    // macOS 13 cascaded into Scene rebuilds + observation churn that
    // broke `MenuBarExtra(.window)`'s NSPanel hosting. With AppKit-
    // level menu bar code and a delegate-owned coordinator, the App
    // scope never observes coordinator @Published changes.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Setup window — auto-opened on first launch by AppDelegate
        // via NotificationCenter, manually re-openable via the popover.
        Window("Bastion Setup", id: "bastion.setup") {
            OnboardingWindow(coordinator: appDelegate.coordinator) {
                UserDefaults.standard.set(true, forKey: "bastion.onboarding.shown")
                ActivationPolicyManager.shared.closeWindow(identifierPrefix: "bastion.setup")
            }
            .environmentObject(appDelegate.coordinator)
            .background(OpenWindowBridge())
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window("Host", id: "bastion.host-editor") {
            HostEditorWindow()
                .environmentObject(appDelegate.coordinator)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Invisible bridge between AppDelegate's onboarding-trigger
/// NotificationCenter post and SwiftUI's `\.openWindow` action.
/// AppDelegate runs outside the SwiftUI environment so it can't call
/// openWindow directly; this view lives inside the Setup Window scene's
/// scope so when the notification fires, `openWindow(id:)` works.
private struct OpenWindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .bastionRequestOpenSetupWindow)) { _ in
                openWindow(id: "bastion.setup")
            }
    }
}

/// Wrapper around `MenuBarLabel` that owns the @ObservedObject
/// subscription to the coordinator. Hosted via `NSHostingView` inside
/// the `NSStatusItem.button` by `AppDelegate`. Observation lives here
/// (a leaf SwiftUI tree) so badge changes redraw the icon without
/// touching the App scene.
struct MenuBarLabelBadge: View {
    @ObservedObject var coordinator: AppCoordinator
    var body: some View {
        MenuBarLabel(
            anyMasterAlive: coordinator.menuBarBadge.anyMasterAlive,
            anyWarning: coordinator.menuBarBadge.anyWarning
        )
    }
}

/// Menu-bar status icon. Vigil's template-image-with-overlay pattern.
struct MenuBarLabel: View {
    let anyMasterAlive: Bool
    let anyWarning: Bool

    var body: some View {
        Image(nsImage: renderedImage())
            .overlay(alignment: .topTrailing) {
                if anyWarning {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                        .offset(x: 1, y: -1)
                }
            }
            .frame(width: 22, height: 22)
            .help(tooltip)
            .accessibilityLabel(tooltip)
    }

    private var tooltip: String {
        let base = anyMasterAlive ? "Bastion — ControlMaster active" : "Bastion"
        return anyWarning ? "\(base) (setup needs attention)" : base
    }

    private func renderedImage() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let symbol = anyMasterAlive ? "link.circle.fill" : "key.horizontal.fill"
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return NSImage()
        }
        if !anyMasterAlive {
            base.isTemplate = true
            return base
        }
        let size = base.size
        let tinted = NSImage(size: size, flipped: false) { rect in
            NSColor.systemGreen.set()
            rect.fill()
            base.draw(
                in: rect,
                from: NSRect(origin: .zero, size: size),
                operation: .destinationIn,
                fraction: 1.0
            )
            return true
        }
        tinted.isTemplate = false
        return tinted
    }
}
