import SwiftUI
import AppKit
import BastionCore

/// Container view for the host editor Window scene. Resolves the
/// coordinator from the environment and delegates to an inner
/// view that holds the editor state as @ObservedObject — without that
/// wrapping, the `Binding(get:set:)` we'd need to construct here
/// wouldn't re-evaluate when state.draft changes, so TextField /
/// Toggle / Picker bindings would only flush on the next external
/// re-render (e.g. moving focus, clicking elsewhere). The wrapper is
/// the SwiftUI-canonical fix for binding through nested ObservableObjects.
struct HostEditorWindow: View {
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        HostEditorWindowContent(state: coordinator.editorState, coordinator: coordinator)
            .managesActivationPolicy(identifierPrefix: "bastion.host-editor")
    }
}

private struct HostEditorWindowContent: View {
    @ObservedObject var state: HostEditorState
    let coordinator: AppCoordinator

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
    }
}
