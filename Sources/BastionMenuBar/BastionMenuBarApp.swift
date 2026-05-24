import SwiftUI
import BastionIdentifiers
import BastionCore

// Bastion menu-bar app — entrypoint.
//
// Commit 1 ships a placeholder MenuBarExtra with the app icon and a
// version label so we can verify the .app bundle launches and the icon
// appears in the menu bar. Real UI (host list, editor, onboarding,
// diagnostics) lands in commits 8+.

@main
struct BastionMenuBarApp: App {
    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                Text("Bastion")
                    .font(.headline)
                Text("Scaffold build · v\(BastionVersion.value)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Text("Full UI lands in commits 8+ of the rollout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(12)
            .frame(width: 280)
        } label: {
            Image(systemName: "key.horizontal.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
