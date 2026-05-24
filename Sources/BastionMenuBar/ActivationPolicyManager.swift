import AppKit
import SwiftUI

/// Temporarily switches an LSUIElement (menu-bar-only) app to the
/// `.regular` activation policy while one of our real windows is open,
/// and restores `.accessory` when the last one closes.
///
/// Per dual-model consensus review (GPT-5.5 + Claude Opus 4.7 1M, both
/// high reasoning), the SwiftUI `onAppear`/`onDisappear` lifecycle is
/// NOT a reliable signal — events double-fire on scene re-instantiation
/// and `onDisappear` is not guaranteed when a window closes via
/// `NSWindow.close()` synchronously from inside the view tree. We
/// observe AppKit truth instead: NSWindow notifications drive a
/// recompute that derives state from `NSApp.windows`.
@MainActor
public final class ActivationPolicyManager {
    public static let shared = ActivationPolicyManager()

    public static let managedIdentifierPrefixes: [String] = [
        "bastion.host-editor",
        "bastion.setup"
    ]

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
        nc.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // willClose fires before the window is removed from
            // NSApp.windows; recompute on the next runloop hop.
            DispatchQueue.main.async {
                Task { @MainActor in self?.recompute() }
            }
        }
    }

    /// Idempotent — recomputes desired policy from the *current* set of
    /// visible managed windows.
    public func recompute() {
        let visibleManaged = NSApp.windows.filter { window in
            guard window.isVisible else { return false }
            guard let id = window.identifier?.rawValue else { return false }
            return Self.managedIdentifierPrefixes.contains { id.hasPrefix($0) }
        }
        let desired: NSApplication.ActivationPolicy = visibleManaged.isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != desired {
            NSApp.setActivationPolicy(desired)
        }
        if !visibleManaged.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Find and bring a managed window to front by id prefix. `hasPrefix`
    /// (SwiftUI appends `-AppWindow-N`) + `isVisible` filter per the
    /// rubber-duck pass.
    @discardableResult
    public func focus(identifierPrefix prefix: String) -> Bool {
        for window in NSApp.windows
        where window.isVisible
            && (window.identifier?.rawValue.hasPrefix(prefix) ?? false) {
            window.makeKeyAndOrderFront(nil)
            return true
        }
        return false
    }

    /// Close a managed window by identifier prefix. Prefers
    /// `performClose(nil)` (standard close pipeline incl.
    /// `windowShouldClose:` + `willCloseNotification`), forces with
    /// `close()` only if still visible next runloop hop.
    public func closeWindow(identifierPrefix prefix: String) {
        for window in NSApp.windows
        where window.identifier?.rawValue.hasPrefix(prefix) == true {
            window.performClose(nil)
            DispatchQueue.main.async {
                if window.isVisible { window.close() }
            }
            return
        }
    }
}

public extension View {
    /// SwiftUI helper. Triggers one recompute + focus on appear;
    /// correctness otherwise comes from the manager's notification
    /// observers (don't refcount view lifecycle events, they double-fire
    /// and skip on re-entry).
    func managesActivationPolicy(identifierPrefix prefix: String) -> some View {
        self.onAppear {
            ActivationPolicyManager.shared.recompute()
            DispatchQueue.main.async {
                ActivationPolicyManager.shared.focus(identifierPrefix: prefix)
            }
        }
    }
}
