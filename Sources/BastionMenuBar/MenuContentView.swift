import SwiftUI
import BastionCore
import BastionIdentifiers

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
        VStack(spacing: 0) {
            header
            Divider()
            errorBanner
            // Direct VStack (no ScrollView) when host count is small:
            // the popover grows naturally to fit content. NSPopover's
            // `contentSize` is driven by `NSHostingController.preferred
            // ContentSize` (set up in AppDelegate.setUpPopover via
            // `sizingOptions = [.preferredContentSize]`), so adding /
            // removing / expanding hosts dynamically resizes the
            // popover with no manual frame management.
            //
            // For very large host lists, wrap in a ScrollView with a
            // sane cap so the popover doesn't exceed screen height.
            if coordinator.status.hosts.isEmpty {
                emptyState
            } else if coordinator.status.hosts.count <= 12 && expandedHostIDs.isEmpty {
                hostList
                    .padding(.vertical, 4)
            } else if coordinator.status.hosts.count <= 8 {
                // Small-ish list with some expanded cards — still fits
                // comfortably without scrolling.
                hostList
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    hostList
                        .padding(.vertical, 4)
                }
                .frame(maxHeight: 600)
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear {
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
                Text(headerSubtitle)
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

    /// Status subtitle for the header. Vigil's pattern — concise
    /// summary of current state, e.g. "Idle" or "Keeping your Mac
    /// awake". For Bastion: count of hosts and active masters.
    /// The timestamp lives in the footer now.
    private var headerSubtitle: String {
        let hosts = coordinator.status.hosts
        if hosts.isEmpty {
            return "No hosts yet"
        }
        let alive = hosts.filter { $0.controlMaster.status == .running }.count
        let hostsWord = hosts.count == 1 ? "host" : "hosts"
        switch alive {
        case 0:
            return "\(hosts.count) \(hostsWord) · idle"
        case hosts.count:
            return "\(hosts.count) \(hostsWord) · all authenticated"
        default:
            return "\(hosts.count) \(hostsWord) · \(alive) authenticated"
        }
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

    /// Per-host list extracted to a computed view so it can be
    /// rendered directly (small lists) or wrapped in a ScrollView
    /// (large lists), without duplicating the ForEach body.
    @ViewBuilder
    private var hostList: some View {
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
    }

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

    /// Bottom bar styled to match Vigil's footer: timestamp/last-message
    /// on the left, terminal picker + icon-only action buttons with
    /// tooltips on the right. Industry-standard menu-bar app footer
    /// pattern (Tailscale, gh, op signin all use icon footers).
    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            Text(coordinator.lastMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            terminalPicker

            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)

            // Refresh status from disk + ssh -O check per host.
            Button {
                Task { await coordinator.refreshNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh status")
            .disabled(coordinator.isRefreshing)

            // Re-open the onboarding / setup window.
            Button {
                openWindow(id: "bastion.setup")
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Re-run setup")

            // Copy diagnostics — same output as `bastion config doctor`.
            // Useful for bug reports / support.
            Button {
                coordinator.copyDiagnostics()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.plain)
            .help("Copy diagnostics to clipboard")

            // Check for updates (Sparkle). Disabled when not configured
            // (debug builds without the appcast URL) or when Sparkle
            // says it's busy.
            Button {
                if updateController.isConfigured {
                    updateController.checkForUpdates()
                }
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .help(updateController.isConfigured
                  ? "Check for updates"
                  : "Auto-updates are configured in signed release builds only")
            .disabled(!updateController.canCheckForUpdates)

            // Quit.
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit Bastion (active master sockets keep running until ControlPersist expires)")
            .keyboardShortcut("q")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
                    .font(.caption)
                Text(coordinator.defaultTerminal?.displayName ?? "Pick terminal")
                    .font(.caption)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Terminal app used for new SSH connections")
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
