import SwiftUI
import BastionCore
import BastionIdentifiers

@main
struct BastionMenuBarApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(coordinator: coordinator)
        } label: {
            MenuBarLabel(
                anyMasterAlive: coordinator.status.hosts.contains { $0.controlMaster.status == .running },
                anyWarning: coordinator.status.iCloudSyncSuspected
                          || !coordinator.status.includeInstalled
            )
        }
        .menuBarExtraStyle(.window)
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
