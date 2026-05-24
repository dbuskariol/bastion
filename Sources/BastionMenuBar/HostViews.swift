import SwiftUI
import BastionCore

/// Compact summary row for a host in the popover list.
struct HostRow: View {
    let host: HostSnapshot
    @Binding var expanded: Bool
    let authState: AppCoordinator.InteractiveAuthState
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            statusDot
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(host.alias)
                        .font(.system(size: 13, weight: .semibold))
                    authChip
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let channels = host.controlMaster.attachedSessions, channels > 0 {
                Text("\(channels)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.tertiary, in: RoundedRectangle(cornerRadius: 4))
            }
            Button(action: onConnect) {
                Image(systemName: "terminal.fill")
            }
            .buttonStyle(.borderless)
            .help("Connect")
            Button(action: { expanded.toggle() }) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
    }

    private var subtitle: String {
        let userPart = host.user.map { "\($0)@" } ?? ""
        let portPart = host.port != 22 ? ":\(host.port)" : ""
        return "\(userPart)\(host.hostname)\(portPart)"
    }

    @ViewBuilder
    private var statusDot: some View {
        let color: Color = {
            switch host.controlMaster.status {
            case .running where (host.controlMaster.attachedSessions ?? 0) > 0:
                return .blue
            case .running:    return .green
            case .stale:      return .yellow
            case .down:       return .secondary
            case .disabled:   return .secondary
            case .unknown:    return .secondary
            }
        }()
        Circle().fill(color)
    }

    @ViewBuilder
    private var authChip: some View {
        switch authState {
        case .notRequired, .ready:
            EmptyView()
        case .authenticating:
            HStack(spacing: 3) {
                ProgressView().controlSize(.mini)
                Text("authenticating")
                    .font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
        case .failed:
            Text("auth failed")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.red.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

/// Expanded diagnostics card for a host. Vigil's `ExpandableDiagnosticsCard`
/// pattern. Polls remote info on-demand only. Each `row` is tap-to-copy
/// with a fade-in / fade-out "Copied!" overlay.
struct HostDetailCard: View {
    let host: HostSnapshot
    let onDisconnect: () -> Void
    let onCopyCommand: () -> Void
    let onConnect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var copiedField: String? = nil
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Resolved address row.
            copyableRow(key: "Address", value: "\(host.hostname):\(host.port)")
            if let user = host.user { copyableRow(key: "User", value: user) }
            if !host.identityFiles.isEmpty {
                copyableRow(key: "Identity", value: host.identityFiles.joined(separator: ", "))
            }
            copyableRow(key: "SSH command", value: "ssh \(host.alias)")
            // Master block (only when configured).
            if host.controlMaster.enabled {
                Divider().padding(.vertical, 2)
                row(key: "Master", value: host.controlMaster.status.rawValue.capitalized)
                if let pid = host.controlMaster.pid {
                    copyableRow(key: "PID", value: "\(pid)")
                }
                if let channels = host.controlMaster.attachedSessions {
                    row(key: "Sessions", value: "\(channels)")
                }
                if let persist = host.controlMaster.persistSeconds, persist > 0 {
                    row(key: "Persist", value: "\(persist / 60)m")
                }
                if let uptimeSeconds = host.uptimeSeconds, uptimeSeconds > 0 {
                    row(key: "Uptime", value: formatDuration(uptimeSeconds))
                }
                if let lastChecked = host.controlMaster.lastCheckedAt {
                    row(key: "Checked", value: Self.timeFormatter.string(from: lastChecked))
                }
                if let socketPath = host.controlMaster.controlPath {
                    copyableRow(key: "Socket", value: socketPath)
                }
            }
            if let lastError = host.lastError {
                Divider().padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(lastError.stderrTail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            HStack(spacing: 8) {
                Button("Open Terminal", action: onConnect)
                    .buttonStyle(.bordered)
                Button("Edit", action: onEdit)
                    .buttonStyle(.bordered)
                if host.controlMaster.status == .running || host.controlMaster.status == .stale {
                    Button("Disconnect", role: .destructive, action: onDisconnect)
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help("Delete this host")
            }
            .font(.caption)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .confirmationDialog(
            "Delete \(host.alias)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(host.alias)", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the host from Bastion (hosts.json) and from ~/.ssh/config.d/bastion.conf. Generated SSH keys in ~/.ssh/ are left in place.")
        }
    }

    // MARK: - Row builders

    /// Non-interactive row (e.g. Master status).
    @ViewBuilder
    private func row(key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.caption).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value).font(.caption.monospaced())
            Spacer()
        }
    }

    /// Tap-to-copy row. Industry-standard pattern: the trailing copy
    /// icon (doc.on.doc) swaps to a green checkmark for ~1.2s on tap.
    /// The value text stays put.
    @ViewBuilder
    private func copyableRow(key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.caption).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value).font(.caption.monospaced())
            Spacer()
            Image(systemName: copiedField == key ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(copiedField == key ? Color.green : Color.secondary)
                .frame(width: 12, height: 12)
                .animation(.easeInOut(duration: 0.15), value: copiedField == key)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { copy(key: key, value: value) }
        .help("Click to copy")
    }

    private func copy(key: String, value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) {
            copiedField = key
        }
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if copiedField == key { copiedField = nil }
                }
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds >= 3600 {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return "\(h)h \(m)m"
        }
        if seconds >= 60 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        return "\(seconds)s"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}
