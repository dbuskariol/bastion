import SwiftUI
import AppKit
import BastionCore

/// Container view for the host editor Window scene. Wires the
/// coordinator's HostEditorState into a HostEditorView that lives in its
/// own native window — so MenuBarExtra(.window) closing the popover on
/// focus shift doesn't take the editor with it.
struct HostEditorWindow: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var state: HostEditorState

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.state = coordinator.editorState
    }

    var body: some View {
        HostEditorView(
            coordinator: coordinator,
            draft: $state.draft,
            originalAlias: state.originalAlias,
            onSaved: {
                state.isReady = false
                closeHostEditorWindow()
            },
            onCancel: {
                state.isReady = false
                closeHostEditorWindow()
            }
        )
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Close the host-editor window without using @Environment(\.dismissWindow)
    /// (which is macOS 14+). NSWindow.close on the matching window
    /// works on macOS 13.
    private func closeHostEditorWindow() {
        for window in NSApp.windows {
            // SwiftUI Window scenes get NSWindow identifiers shaped like
            // "bastion.host-editor-AppWindow-1". Match on prefix.
            if window.identifier?.rawValue.contains("bastion.host-editor") == true {
                window.close()
                return
            }
        }
        // Fallback: close the key window.
        NSApp.keyWindow?.close()
    }
}
