import SwiftUI
import BastionCore

/// Compact summary row for a host in the popover list.
struct HostRow: View {
    let host: HostSnapshot
    @Binding var expanded: Bool
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            statusDot
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.alias)
                    .font(.system(size: 13, weight: .semibold))
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
}

/// Expanded diagnostics card for a host. Vigil's `ExpandableDiagnosticsCard`
/// pattern. Polls remote info on-demand only.
struct HostDetailCard: View {
    let host: HostSnapshot
    let onDisconnect: () -> Void
    let onCopyCommand: () -> Void
    let onConnect: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Resolved address row.
            row("Address", "\(host.hostname):\(host.port)")
            if let user = host.user { row("User", user) }
            if !host.identityFiles.isEmpty {
                row("Identity", host.identityFiles.joined(separator: ", "))
            }
            // Master block (only when configured).
            if host.controlMaster.enabled {
                Divider().padding(.vertical, 2)
                row("Master", host.controlMaster.status.rawValue.capitalized)
                if let pid = host.controlMaster.pid {
                    row("PID", "\(pid)")
                }
                if let channels = host.controlMaster.attachedSessions {
                    row("Sessions", "\(channels)")
                }
                if let persist = host.controlMaster.persistSeconds, persist > 0 {
                    row("Persist", "\(persist / 60)m")
                }
                if let uptimeSeconds = host.uptimeSeconds, uptimeSeconds > 0 {
                    row("Uptime", formatDuration(uptimeSeconds))
                }
                if let lastChecked = host.controlMaster.lastCheckedAt {
                    row("Checked", Self.timeFormatter.string(from: lastChecked))
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
                Button("Copy ssh", action: onCopyCommand)
                    .buttonStyle(.bordered)
                Spacer()
            }
            .font(.caption)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.caption).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value).font(.caption.monospaced())
            Spacer()
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
