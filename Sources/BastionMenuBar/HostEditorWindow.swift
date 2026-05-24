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
                ActivationPolicyManager.shared.closeWindow(identifierPrefix: "bastion.host-editor")
            },
            onCancel: {
                state.isReady = false
                ActivationPolicyManager.shared.closeWindow(identifierPrefix: "bastion.host-editor")
            }
        )
        .managesActivationPolicy(identifierPrefix: "bastion.host-editor")
    }
}
