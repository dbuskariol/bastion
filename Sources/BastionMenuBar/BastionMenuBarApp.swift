import SwiftUI
import BastionCore
import BastionIdentifiers

@main
struct BastionMenuBarApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var updateController = UpdateController()
    @Environment(\.openWindow) private var openWindow

    /// Sticky flag — once the user has gone through (or dismissed) the
    /// onboarding window, never re-trigger it automatically. They can
    /// re-open it manually from the popover footer if needed.
    @AppStorage("bastion.onboarding.shown") private var onboardingHasShown: Bool = false

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(coordinator: coordinator, updateController: updateController)
        } label: {
            MenuBarLabel(
                anyMasterAlive: coordinator.status.hosts.contains { $0.controlMaster.status == .running },
                anyWarning: coordinator.status.iCloudSyncSuspected
                          || !coordinator.status.includeInstalled
            )
            .background(OnboardingTrigger(coordinator: coordinator, hasShown: $onboardingHasShown))
        }
        .menuBarExtraStyle(.window)

        Window("Bastion Setup", id: "bastion.setup") {
            OnboardingWindow(coordinator: coordinator) {
                onboardingHasShown = true
                ActivationPolicyManager.shared.closeWindow(identifierPrefix: "bastion.setup")
            }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Separate Window scene for the host editor so it survives the
        // popover closing on focus shift.
        Window("Host", id: "bastion.host-editor") {
            HostEditorWindow(coordinator: coordinator)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Auto-opens the Setup window once on first launch. Hosted inside the
/// MenuBarExtra label's `.background` so it's always in the scene graph
/// (Vigil pattern). Backed by `@AppStorage` because `@State` here resets
/// every time SwiftUI recreates the trigger view (which happens whenever
/// the menu-bar label re-renders), which was the bug source: every host
/// add caused the wizard to re-fire.
private struct OnboardingTrigger: View {
    @ObservedObject var coordinator: AppCoordinator
    @Binding var hasShown: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                guard !hasShown else { return }
                Task {
                    // Wait briefly so the initial status refresh populates.
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !hasShown else { return }
                    let isEmpty = coordinator.engine.store.isEmpty()
                    if isEmpty {
                        await MainActor.run {
                            hasShown = true
                            openWindow(id: "bastion.setup")
                        }
                    } else {
                        // Hosts exist — user is past first run. Mark
                        // onboarding as already shown so we never
                        // auto-open it for them.
                        await MainActor.run { hasShown = true }
                    }
                }
            }
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
