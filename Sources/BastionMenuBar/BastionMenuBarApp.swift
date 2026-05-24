import SwiftUI
import BastionCore
import BastionIdentifiers

@main
struct BastionMenuBarApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var updateController = UpdateController()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(coordinator: coordinator, updateController: updateController)
        } label: {
            MenuBarLabel(
                anyMasterAlive: coordinator.status.hosts.contains { $0.controlMaster.status == .running },
                anyWarning: coordinator.status.iCloudSyncSuspected
                          || !coordinator.status.includeInstalled
            )
            .background(OnboardingTrigger(coordinator: coordinator))
        }
        .menuBarExtraStyle(.window)

        Window("Bastion Setup", id: "bastion.setup") {
            OnboardingWindow(coordinator: coordinator) {
                NSApp.keyWindow?.close()
            }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Auto-opens the Setup window once on first launch. Hosted inside the
/// MenuBarExtra label's `.background` so it's always in the scene graph
/// (Vigil pattern).
private struct OnboardingTrigger: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow
    @State private var didTrigger = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                guard !didTrigger else { return }
                Task {
                    // Wait briefly so the initial status refresh populates.
                    try? await Task.sleep(for: .milliseconds(800))
                    let isEmpty = coordinator.engine.store.isEmpty()
                    if isEmpty {
                        await MainActor.run {
                            didTrigger = true
                            openWindow(id: "bastion.setup")
                        }
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
