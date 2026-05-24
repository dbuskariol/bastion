import AppKit
import Foundation
import Security
import BastionIdentifiers

/// `SecTranslocateCreateOriginalPathForURL` (Security.framework, public
/// since macOS 10.12) isn't auto-bridged into Swift. Declare it.
@_silgen_name("SecTranslocateCreateOriginalPathForURL")
private func _SecTranslocateCreateOriginalPathForURL(
    _ translocatedURL: CFURL,
    _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
) -> Unmanaged<CFURL>?

/// Detect Gatekeeper Path Randomization (App Translocation) and offer to
/// move the bundle to /Applications. Adapted verbatim from Vigil — the
/// behaviour is identical (translocation breaks our `~/.ssh/config.d/
/// bastion.conf` writes if the path is ephemeral).
enum AppRelocator {

    enum RelocationError: Error, CustomStringConvertible, Equatable {
        case alreadyExists
        case copyFailed(String)
        case sourceUnreadable
        var description: String {
            switch self {
            case .alreadyExists:
                return "Another copy of Bastion.app already exists at /Applications. Replace it to continue."
            case .copyFailed(let m):
                return "Move failed: \(m)"
            case .sourceUnreadable:
                return "Could not read the current Bastion.app bundle."
            }
        }
    }

    static var currentBundleURL: URL { Bundle.main.bundleURL }
    static var targetURL: URL { URL(fileURLWithPath: "/Applications/Bastion.app") }

    static var isAlreadyInApplications: Bool {
        currentBundleURL.standardizedFileURL.path
            == targetURL.standardizedFileURL.path
    }

    static func originalBundleURL() -> URL {
        var err: Unmanaged<CFError>?
        if let resolved = _SecTranslocateCreateOriginalPathForURL(
            currentBundleURL as CFURL, &err
        )?.takeRetainedValue() {
            return resolved as URL
        }
        return currentBundleURL
    }

    static func existingApplicationsCopyIsBastion() -> Bool {
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return false }
        return Bundle(url: targetURL)?.bundleIdentifier == BastionIdentifiers.bundleID
    }

    /// Idempotent: returns immediately if already in /Applications.
    /// On success, relaunches from the new location and terminates the
    /// current (translocated) process.
    @MainActor
    static func moveAndRelaunch() throws {
        if isAlreadyInApplications { return }

        let source = originalBundleURL()
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RelocationError.sourceUnreadable
        }

        if FileManager.default.fileExists(atPath: targetURL.path) {
            if existingApplicationsCopyIsBastion() {
                // OK to replace.
                try FileManager.default.removeItem(at: targetURL)
            } else {
                throw RelocationError.alreadyExists
            }
        }

        do {
            try FileManager.default.copyItem(at: source, to: targetURL)
        } catch {
            throw RelocationError.copyFailed(error.localizedDescription)
        }

        // Best-effort: strip the quarantine attribute so Gatekeeper
        // doesn't re-translocate on relaunch.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-d", "-r", "com.apple.quarantine", targetURL.path]
        try? xattr.run()
        xattr.waitUntilExit()

        // Relaunch from the new path; terminate current process.
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = [targetURL.path]
        try opener.run()
        // Give launchd a beat to register the new instance.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }
}
