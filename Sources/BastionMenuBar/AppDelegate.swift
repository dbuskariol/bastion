import AppKit
import SwiftUI
import Combine
import os
import BastionCore

/// AppKit-level menu-bar orchestration. Replaces the SwiftUI
/// `MenuBarExtra(.window)` scene which is structurally broken on
/// macOS 13:
///
///   - Its private NSPanel hosts the popover content via an opaque
///     `NSHostingView` that does NOT re-negotiate `intrinsicContentSize`
///     when the SwiftUI body's layout shape changes. Result: when the
///     popover materialises with one content shape (e.g. `emptyState`)
///     and the body subsequently switches branches (e.g. `ScrollView`
///     with N rows), the panel keeps the original size and the new
///     content is rendered but clipped to zero height. Visible to the
///     user as "popover shows empty area between header and footer
///     forever after restart".
///
///   - The label closure is evaluated at Scene scope; any `@Published`
///     read there re-evaluates the App body, which rebuilds the Scene
///     primitive, which detaches the NSPanel's content observation.
///     We worked around with `MenuBarLabelBadge` but the underlying
///     fragility remains.
///
/// `NSStatusItem` + `NSPopover` + `NSHostingController` is the
/// production-grade alternative used by every mature macOS menu-bar
/// app (Vigil included). The hosting controller's `preferredContentSize`
/// flows directly into `NSPopover.contentSize` whenever SwiftUI
/// recomputes the body's ideal size, so the popover grows and shrinks
/// dynamically as the user adds/removes hosts.
///
/// Per dual-model consensus (GPT-5.5 + Opus 4.7 1M, both with
/// high reasoning) — they converged independently on this migration
/// as the no-hacks fix.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    // Coordinator + update controller live here so they outlive any
    // particular Scene's lifecycle and have no @StateObject /
    // @ObservedObject ties to the App's body — the source of the
    // scene-rebuild churn that broke MenuBarExtra observation.
    let coordinator = AppCoordinator()
    let updateController = UpdateController()

    private static let log = Logger(subsystem: "com.bastion.menu", category: "appdelegate")

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var labelHostingView: NSHostingView<MenuBarLabelBadge>!
    private var outsideClickMonitor: Any?
    private var preferredContentSizeObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.log.info("applicationDidFinishLaunching")
        // Belt-and-suspenders against macOS state restoration. The
        // SwiftUI Window scenes have `NonRestorableWindow` applied at
        // the per-window level, but registering this default flips off
        // the "Reopen windows when logging back in" behavior at the
        // app level too. Without it, the Setup window would re-open
        // on every launch even after the user completed onboarding,
        // because macOS persists window frames under `NSWindow Frame
        // <id>` and the system's window-restoration pass tries to
        // recreate them.
        UserDefaults.standard.register(defaults: [
            "NSQuitAlwaysKeepsWindows": false
        ])
        setUpStatusItem()
        setUpPopover()
        autoTriggerOnboardingIfNeeded()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        labelHostingView = NSHostingView(
            rootView: MenuBarLabelBadge(coordinator: coordinator)
        )
        labelHostingView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(labelHostingView)
        NSLayoutConstraint.activate([
            labelHostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            labelHostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            labelHostingView.topAnchor.constraint(equalTo: button.topAnchor),
            labelHostingView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        button.target = self
        button.action = #selector(togglePopover(_:))
    }

    // MARK: - Popover

    private func setUpPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        let content = MenuContentView()
            .environmentObject(coordinator)
            .environmentObject(updateController)
        let hostingController = NSHostingController(rootView: content)
        // sizingOptions automatically syncs preferredContentSize with
        // the SwiftUI body's ideal size, which the popover then mirrors
        // into its NSPanel frame. THIS is what gives us dynamic
        // resizing as the user adds/removes hosts — `MenuBarExtra(.window)`
        // explicitly does not honor this on macOS 13.
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController

        // Observe `preferredContentSize` so we can log size changes
        // for diagnostics — also a load-bearing hook because some
        // macOS 13 corner cases need an explicit popover.contentSize
        // assignment to actually trigger the panel resize.
        preferredContentSizeObservation = hostingController.observe(
            \.preferredContentSize,
            options: [.new]
        ) { [weak self] _, change in
            guard let new = change.newValue else { return }
            Self.log.info("preferredContentSize -> \(NSStringFromSize(new), privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                self?.popover.contentSize = new
            }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        Self.log.info("popoverDidShow size=\(NSStringFromSize(self.popover.contentSize), privacy: .public)")
        coordinator.popoverDidOpen()
    }

    func popoverDidClose(_ notification: Notification) {
        Self.log.info("popoverDidClose")
        coordinator.popoverDidClose()
    }

    // MARK: - Onboarding bootstrap

    /// On first launch (no `bastion.onboarding.shown` set in UserDefaults),
    /// pop the Setup window if the host registry is empty. Replaces the
    /// previous `OnboardingTrigger` SwiftUI workaround that lived in
    /// the MenuBarExtra label's `.background()`.
    private func autoTriggerOnboardingIfNeeded() {
        let shown = UserDefaults.standard.bool(forKey: "bastion.onboarding.shown")
        guard !shown else { return }
        Task { @MainActor in
            // Give the initial status refresh a moment to populate.
            try? await Task.sleep(for: .milliseconds(800))
            let isEmpty = coordinator.engine.store.isEmpty()
            UserDefaults.standard.set(true, forKey: "bastion.onboarding.shown")
            guard isEmpty else { return }
            // Open the Setup window via SwiftUI's openWindow action.
            // We grab it from any active scene's environment.
            NotificationCenter.default.post(
                name: .bastionRequestOpenSetupWindow,
                object: nil
            )
        }
    }
}

extension Notification.Name {
    /// Posted by `AppDelegate` when onboarding should auto-open. A
    /// hidden background view in the App scene listens for this and
    /// invokes `openWindow(id: "bastion.setup")` — this bridges
    /// AppDelegate (no SwiftUI environment) to the App scene's
    /// window-opening machinery.
    static let bastionRequestOpenSetupWindow = Notification.Name("com.bastion.menu.openSetup")
}
