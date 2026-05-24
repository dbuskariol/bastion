import SwiftUI
import AppKit
import BastionCore

/// Container view for the host editor Window scene. Wires the
/// coordinator's HostEditorState into a HostEditorView that lives in its
/// own native window — so MenuBarExtra(.window) closing the popover on
/// focus shift doesn't take the editor with it.
struct HostEditorWindow: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @ObservedObject private var state: HostEditorState
    private weak var coordinatorRef: AppCoordinator?

    init() {
        // SwiftUI Window content init is called before the
        // environment is resolved, so we can't read @EnvironmentObject
        // here. The state binding happens lazily in body via the
        // resolved coordinator from the environment.
        // Use a placeholder; body switches to coordinator.editorState.
        self.state = HostEditorState()
    }

    var body: some View {
        // Always read state from the *environment-resolved* coordinator,
        // never from the placeholder we constructed in init.
        let liveState = coordinator.editorState
        HostEditorView(
            coordinator: coordinator,
            draft: Binding(
                get: { liveState.draft },
                set: { liveState.draft = $0 }
            ),
            originalAlias: liveState.originalAlias,
            onSaved: {
                liveState.isReady = false
                ActivationPolicyManager.shared.closeWindow(identifierPrefix: "bastion.host-editor")
            },
            onCancel: {
                liveState.isReady = false
                ActivationPolicyManager.shared.closeWindow(identifierPrefix: "bastion.host-editor")
            }
        )
        .managesActivationPolicy(identifierPrefix: "bastion.host-editor")
    }
}
