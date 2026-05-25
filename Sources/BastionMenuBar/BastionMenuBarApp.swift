import SwiftUI
import BastionCore
import BastionIdentifiers

@main
struct BastionMenuBarApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var updateController = UpdateController()
    @Environment(\.openWindow) private var openWindow

    /// Sticky flag — once the user has gone through (or dismissed) the
    /// onboarding window, never re-trigger it automatically.
    @AppStorage("bastion.onboarding.shown") private var onboardingHasShown: Bool = false

    var body: some Scene {
        MenuBarExtra {
            // Inject the coordinator + update controller via environment
            // so MenuContentView (hosted inside MenuBarExtra(.window)'s
            // private NSPanel) re-subscribes at view-tree insertion time
            // — rather than relying on a constructor-captured
            // @ObservedObject wrapper that the panel latches on first
            // open and never re-arms when the App scene re-evaluates.
            // Diagnosed via dual-model consensus.
            MenuContentView()
                .environmentObject(coordinator)
                .environmentObject(updateController)
        } label: {
            // CRITICAL: do NOT read any `coordinator.@Published` directly
            // in this closure. Wrap the badge consumption in a child
            // view (`MenuBarLabelBadge`) that does the observation
            // internally. Reading `coordinator.menuBarBadge.X` here
            // re-evaluates the App scene on every badge change, which
            // tears down the popover's hosting NSPanel and breaks its
            // observation chain — visible to the user as "popover shows
            // stale state forever after the first poll-induced badge
            // transition". Same root cause as why we don't read
            // `coordinator.status` here. Diagnosed via dual-model
            // consensus + rubber-duck, second pass.
            MenuBarLabelBadge(coordinator: coordinator)
                .background(OnboardingTrigger(coordinator: coordinator, hasShown: $onboardingHasShown))
        }
        .menuBarExtraStyle(.window)

        Window("Bastion Setup", id: "bastion.setup") {
            OnboardingWindow(coordinator: coordinator) {
                onboardingHasShown = true
                ActivationPolicyManager.shared.closeWindow(identifierPrefix: "bastion.setup")
            }
            .environmentObject(coordinator)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window("Host", id: "bastion.host-editor") {
            HostEditorWindow()
                .environmentObject(coordinator)
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
///
/// Coordinator is passed as a plain `let`, NOT `@ObservedObject`. We
/// only consult it inside `onAppear` (one-shot action, not observation)
/// — observing here would cause this view to re-render on every poll
/// refresh, which cascades into App-scene re-evaluation and tears down
/// the popover hosting view's observation chain. The popover then
/// shows stale state forever. Diagnosed via dual-model consensus +
/// rubber-duck, second pass.
private struct OnboardingTrigger: View {
    let coordinator: AppCoordinator
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

/// Wrapper around `MenuBarLabel` that owns the @ObservedObject
/// subscription to the coordinator. This view re-renders on every
/// `menuBarBadge` change — which is fine because it's a leaf view
/// (`Image` + overlay) — but crucially the SUBSCRIPTION lives here
/// instead of in the App scene's label closure. Reading
/// `coordinator.menuBarBadge.X` at the App-scene scope re-evaluates
/// the App body on every badge change, which tears down the
/// MenuBarExtra(.window) popover's hosting NSPanel and breaks its
/// observation of `coordinator.status.hosts`. Visible to the user as
/// a popover that shows the empty initial state forever after the
/// first poll-induced badge transition (e.g. masters come up after
/// the user's first FIDO touch since launch).
private struct MenuBarLabelBadge: View {
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
