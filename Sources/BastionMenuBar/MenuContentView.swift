import SwiftUI
import os
import BastionCore
import BastionIdentifiers

/// Logger for popover layout/observation debugging. NSLog from a
/// SwiftUI body doesn't surface reliably under `process == "Bastion"`
/// in `log show`; `os.Logger` with an explicit subsystem does.
///   log stream --predicate 'subsystem == "com.bastion.menu"' --level info
private let popoverLog = Logger(subsystem: "com.bastion.menu", category: "popover")

/// The main popover content. Vigil's `MenuContentView` shape adapted to
/// Bastion's host-list use case.
///
/// Per dual-model consensus, the root `VStack` carries
/// `.id(coordinator.menuRevision)` so any registry mutation (add /
/// edit / delete / import) forces SwiftUI to discard this subtree and
/// mount a fresh one. That bypasses the macOS 13 MenuBarExtra(.window)
/// hosting-view cache that otherwise leaves the popover showing stale
/// state until the app is restarted.
struct MenuContentView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var updateController: UpdateController
    @State private var expandedHostIDs: Set<UUID> = []
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Per dual-model consensus: the body re-evaluates correctly on
        // every refresh (proven empirically — `lastMessage` and warning
        // chips update), but the host-list region was producing zero
        // visible output on macOS 13. Root cause: `MenuBarExtra(.window)`'s
        // private NSPanel does NOT re-negotiate `intrinsicContentSize`
        // when the body transitions from `emptyState` to `ScrollView`
        // with N rows. `Text` and warning-chip leaves don't need a
        // layout pass so they update fine; the `ScrollView` (with no
        // minHeight) collapses to 0pt in the size-locked NSPanel and
        // the host list is rendered but invisible. Fix: enforce a
        // `minHeight` on both branches so neither can collapse below
        // a sane floor, AND on the root VStack so the panel has a
        // stable size to negotiate against.
        let hostCount = coordinator.status.hosts.count
        popoverLog.info("body eval: hosts=\(hostCount, privacy: .public) rev=\(self.coordinator.menuRevision, privacy: .public) lastMsg=\(self.coordinator.lastMessage, privacy: .public)")
        return VStack(spacing: 0) {
            header
            Divider()
            errorBanner
            // Eager VStack (not LazyVStack) — at <=200 hosts in a 380pt
            // popover, virtualisation cost is trivial and we avoid the
            // class of macOS 13 SwiftUI bugs where lazy children fail
            // to materialise after a hosting-view cycle.
            if coordinator.status.hosts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(coordinator.status.hosts) { host in
                            VStack(spacing: 4) {
                                HostRow(
                                    host: host,
                                    expanded: binding(for: host.id),
                                    authState: coordinator.authState(for: host),
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
                                        onEdit: { openEditor(for: host.alias) },
                                        onDelete: { coordinator.deleteHost(host.alias) },
                                        onUnlock: { coordinator.unlockMaster(host.alias) },
                                        orphanCount: coordinator.orphansByAlias[host.alias]?.count ?? 0,
                                        onReapOrphans: { coordinator.reapOrphans(for: host.alias) }
                                    )
                                }
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // minHeight is load-bearing — see comment at top of body.
                .frame(minHeight: 120, maxHeight: 420)
            }
            Divider()
            footer
        }
        .id(coordinator.menuRevision)
        // minHeight on the root ensures the NSPanel has a stable size
        // floor it can grow from, instead of locking to the smallest
        // intrinsic ever observed.
        .frame(minWidth: 380, idealWidth: 380, maxWidth: 380, minHeight: 180)
        .onAppear {
            popoverLog.info("onAppear: hosts=\(self.coordinator.status.hosts.count, privacy: .public) rev=\(self.coordinator.menuRevision, privacy: .public)")
            coordinator.popoverDidOpen()
        }
        .onDisappear { coordinator.popoverDidClose() }
        .sheet(isPresented: $coordinator.fidoMigrationDialogPresented) {
            FidoMigrationSheet(
                candidates: coordinator.fidoMigrationCandidates,
                onFixAll: {
                    coordinator.fidoMigrationFixAll()
                },
                onReviewEach: {
                    // Mark acked (the per-host editor warning will
                    // still fire as the user opens each one) and let
                    // them work through manually.
                    coordinator.ackFidoMigration()
                    if let first = coordinator.fidoMigrationCandidates.first {
                        openEditor(for: first.alias)
                    }
                },
                onNotNow: {
                    coordinator.ackFidoMigration()
                }
            )
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let err = coordinator.lastError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(err)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    coordinator.lastError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.08))
            Divider()
        }
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
        Button("Unlock for the day")  { coordinator.unlockMaster(host.alias) }
            .help("Pre-authenticate so subsequent connects are instant for the ControlPersist window.")
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
        // Match the populated branch's `.frame(minHeight:)` so the
        // NSPanel sizes the popover consistently regardless of which
        // branch is active — see body's comment about NSPanel size
        // negotiation on macOS 13.
        .frame(maxWidth: .infinity, minHeight: 120)
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
