import Combine
import Foundation
import Sparkle
import BastionIdentifiers

/// Wraps SPUStandardUpdaterController. Stays inert at runtime unless the
/// `Info.plist` has both `SUFeedURL` and `SUPublicEDKey` set — `make app`
/// builds don't inject those, so Sparkle is a no-op during dev. Only
/// `make release` injects them.
@MainActor
final class UpdateController: ObservableObject {
    @Published var canCheckForUpdates = false

    private let updaterController: SPUStandardUpdaterController?
    private let sparkleDelegate: SparkleDelegate?

    init() {
        guard Self.configurationIsPresent else {
            updaterController = nil
            sparkleDelegate = nil
            return
        }
        let delegate = SparkleDelegate()
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        sparkleDelegate = delegate
        updaterController = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    var isConfigured: Bool {
        updaterController != nil
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    private static var configurationIsPresent: Bool {
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return false
        }
        return URL(string: feedURL)?.scheme == "https"
            && !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Sparkle delegate hook. Used so we can perform any pre-update teardown.
/// Bastion has nothing to bootout (no LaunchAgents), so this is mostly
/// a hook for future use.
final class SparkleDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        // No-op for now — masters are independent ssh processes that survive
        // the .app bundle swap. Coordinator will rebuild the StatusReport
        // from a fresh ConnectionEngine on relaunch.
    }
}
