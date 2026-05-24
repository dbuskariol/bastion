import SwiftUI
import BastionCore
import BastionIdentifiers

/// The main popover content. Vigil's `MenuContentView` shape adapted to
/// Bastion's host-list use case.
struct MenuContentView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var updateController: UpdateController
    @State private var expandedHostIDs: Set<UUID> = []
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if coordinator.status.hosts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(coordinator.status.hosts) { host in
                            VStack(spacing: 4) {
                                HostRow(
                                    host: host,
                                    expanded: binding(for: host.id),
                                    onConnect: { coordinator.connect(host.alias) }
                                )
                                .contextMenu {
                                    contextMenu(for: host)
                                }
                                if expandedHostIDs.contains(host.id) {
                                    HostDetailCard(
                                        host: host,
                                        onDisconnect: { coordinator.disconnectMaster(host.alias) },
                                        onCopyCommand: { coordinator.copyConnectCommand(host.alias) },
                                        onConnect: { coordinator.connect(host.alias) },
                                        onEdit: { openEditor(for: host.alias) }
                                    )
                                }
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 420)
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear { coordinator.popoverDidOpen() }
        .onDisappear { coordinator.popoverDidClose() }
    }

    private func openEditor(for alias: String? = nil) {
        coordinator.openHostEditor(for: alias)
        openWindow(id: "bastion.host-editor")
    }

    private func binding(for hostID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedHostIDs.contains(hostID) },
            set: { isOn in
                if isOn { expandedHostIDs.insert(hostID) }
                else    { expandedHostIDs.remove(hostID) }
            }
        )
    }

    @ViewBuilder
    private func contextMenu(for host: HostSnapshot) -> some View {
        Button("Connect")             { coordinator.connect(host.alias) }
        Button("Connect (new window)") { coordinator.connect(host.alias, newWindow: true) }
        Divider()
        Button("Edit…")               { openEditor(for: host.alias) }
        Button("Copy ssh command")    { coordinator.copyConnectCommand(host.alias) }
        Button("Open in ~/.ssh/config") { coordinator.openManagedConfig() }
        if host.controlMaster.status == .running || host.controlMaster.status == .stale {
            Divider()
            Button("Disconnect ControlMaster") { coordinator.disconnectMaster(host.alias) }
        }
        Divider()
        Button("Delete \(host.alias)…", role: .destructive) {
            coordinator.deleteHost(host.alias)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Bastion")
                    .font(.system(size: 13, weight: .semibold))
                Text(coordinator.lastMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            warningButtons
            Button(action: { openEditor() }) {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("Add host")
        }
        .padding(10)
    }

    @ViewBuilder
    private var warningButtons: some View {
        if coordinator.status.oneOnePasswordAgentDetected {
            WarningButton(
                icon: "key.fill",
                color: .orange,
                title: "1Password SSH agent detected",
                message: "Bastion will not call ssh-add against the 1Password agent (it refuses added keys). Your existing 1Password keys still work — they're served by the agent, and ssh hosts that need them will be authenticated automatically.",
                primary: nil
            )
        }
        if coordinator.status.iCloudSyncSuspected {
            WarningButton(
                icon: "icloud.fill",
                color: .orange,
                title: "~/.ssh appears synced across Macs",
                message: "Concurrent edits from another Mac may conflict with Bastion-managed files. Bastion only writes to ~/.ssh/config.d/bastion.conf and the single Include line in ~/.ssh/config — other config you manage by hand is untouched.",
                primary: WarningAction(label: "Open docs") {
                    if let url = URL(string: "https://github.com/dbuskariol/bastion#multi-mac-sync") {
                        NSWorkspace.shared.open(url)
                    }
                }
            )
        }
        if !coordinator.status.includeInstalled {
            WarningButton(
                icon: "exclamationmark.triangle.fill",
                color: .orange,
                title: "Include block missing",
                message: "Bastion needs one `Include ~/.ssh/config.d/*.conf` line at the top of your ~/.ssh/config so other tools (scp, rsync, mosh, git, VSCode Remote-SSH) see your managed hosts. We can add it now — it's a 3-line sentinel-guarded block that's clean to uninstall.",
                primary: WarningAction(label: "Install now") {
                    coordinator.installSSHConfigInclude()
                }
            )
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            Text("No hosts yet")
                .font(.system(size: 13, weight: .medium))
            Text("Run `bastion import all --apply` to bring in connections\nfrom your shell history, or add one manually.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            Button("Add host") { openEditor() }
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            terminalPicker
            Spacer()
            if updateController.isConfigured {
                Button("Check for updates") {
                    updateController.checkForUpdates()
                }
                .buttonStyle(.borderless)
                .disabled(!updateController.canCheckForUpdates)
            }
            Button("Refresh") {
                Task { await coordinator.refreshNow() }
            }
            .buttonStyle(.borderless)
            .disabled(coordinator.isRefreshing)
            Button("Re-run setup") {
                openWindow(id: "bastion.setup")
            }
            .buttonStyle(.borderless)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .font(.caption)
        .padding(10)
    }

    @ViewBuilder
    private var terminalPicker: some View {
        Menu {
            Picker("Terminal", selection: terminalBinding) {
                ForEach(TerminalID.allCases, id: \.self) { id in
                    let snapshot = coordinator.detector.snapshot(for: id)
                    if snapshot.installed {
                        Text(id.displayName).tag(Optional(id))
                    }
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "macwindow")
                Text(coordinator.defaultTerminal?.displayName ?? "Pick terminal")
                    .font(.caption)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var terminalBinding: Binding<TerminalID?> {
        Binding(
            get: { coordinator.defaultTerminal },
            set: { newValue in
                if let id = newValue {
                    coordinator.setDefaultTerminal(id)
                }
            }
        )
    }
}
