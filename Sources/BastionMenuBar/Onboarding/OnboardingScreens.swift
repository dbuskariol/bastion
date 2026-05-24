import SwiftUI
import BastionCore
import BastionIdentifiers

struct WelcomeScreen: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Bastion")
                .font(.system(size: 28, weight: .semibold))
            Text("One place for every SSH connection.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("""
            Bastion manages every host you've ever connected to from the menu \
            bar: per-host keys, one-click ControlMaster keepalive, Connect-in-your-terminal-of-choice, \
            and a single managed file under ~/.ssh/config.d/bastion.conf that every other \
            tool you use (scp, rsync, mosh, git, VSCode Remote-SSH) automatically sees.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity)
    }
}

struct MoveScreen: View {
    @ObservedObject var model: OnboardingModel
    @State private var actionInProgress = false
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Move Bastion to /Applications", systemImage: "arrow.down.app.fill")
                .font(.system(size: 14, weight: .semibold))
            Text("""
            macOS Gatekeeper randomises the path of unmoved apps from your Downloads folder. \
            That path disappears on next reboot — which would silently break the symlinks Bastion writes. \
            Moving the app to /Applications fixes this for good.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)

            if AppRelocator.isAlreadyInApplications {
                Label("Bastion is in /Applications. Nothing to do.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                HStack {
                    Button(actionInProgress ? "Moving…" : "Move and relaunch") {
                        actionInProgress = true
                        actionError = nil
                        do {
                            try AppRelocator.moveAndRelaunch()
                        } catch {
                            actionError = "\(error)"
                            actionInProgress = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(actionInProgress)
                    Spacer()
                }
                if let actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

struct TerminalScreen: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Choose your default terminal", systemImage: "macwindow")
                .font(.system(size: 14, weight: .semibold))
            Text("""
            Connect from Bastion's menu bar opens the terminal you pick here. We've detected \
            \(installedCount()) installed terminal\(installedCount() == 1 ? "" : "s").
            """)
            .font(.caption).foregroundStyle(.secondary)

            VStack(spacing: 4) {
                ForEach(TerminalID.allCases, id: \.self) { id in
                    let snapshot = coordinator.detector.snapshot(for: id)
                    if snapshot.installed {
                        HStack {
                            Image(systemName: id == model.selectedTerminal ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(.tint)
                            Text(id.displayName)
                            Spacer()
                            if let p = snapshot.appPath ?? snapshot.cliPath {
                                Text(p)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(id == model.selectedTerminal ? Color.accentColor.opacity(0.1) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedTerminal = id }
                    }
                }
            }
            if let suggested = coordinator.detector.suggestedDefault(),
               model.selectedTerminal != suggested {
                Text("Suggested default: \(suggested.displayName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func installedCount() -> Int {
        TerminalID.allCases.filter { coordinator.detector.snapshot(for: $0).installed }.count
    }
}

struct ImportScreen: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Import existing SSH hosts", systemImage: "tray.and.arrow.down")
                .font(.system(size: 14, weight: .semibold))
            Text("""
            We've scanned your shell history and known_hosts for ssh / scp / rsync / mosh / git \
            invocations. Pick which ones to save as Bastion-managed hosts. We never persist your shell \
            history — only the entries you check below.
            """)
            .font(.caption).foregroundStyle(.secondary)

            if model.importCandidates.isEmpty {
                Text("No candidates found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Select all") {
                        model.importSelections = Set(model.importCandidates.filter { !$0.alreadyManaged }.map { $0.id })
                    }
                    Button("None") { model.importSelections.removeAll() }
                    Spacer()
                    Text("\(model.importSelections.count) of \(model.importCandidates.count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .font(.caption)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.importCandidates, id: \.id) { candidate in
                            ImportRow(candidate: candidate, selections: $model.importSelections)
                        }
                    }
                }
                .frame(maxHeight: 240)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

struct ImportRow: View {
    let candidate: ImportCandidate
    @Binding var selections: Set<ParsedConnection.DedupKey>

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .foregroundStyle(isChecked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .onTapGesture { toggle() }
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.suggestedAlias)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if candidate.alreadyManaged {
                Text("MANAGED")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
    }

    private var isChecked: Bool { selections.contains(candidate.id) }
    private func toggle() {
        if candidate.alreadyManaged { return }
        if isChecked { selections.remove(candidate.id) }
        else { selections.insert(candidate.id) }
    }
    private var subtitle: String {
        let userPart = candidate.user.map { "\($0)@" } ?? ""
        let portPart = candidate.port != 22 ? ":\(candidate.port)" : ""
        let sourcesStr = candidate.sources.map { $0.displayName }.sorted().joined(separator: ", ")
        return "\(userPart)\(candidate.hostname)\(portPart) · \(sourcesStr) × \(candidate.invocationCount)"
    }
}

struct SSHConfigScreen: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Add Bastion to your SSH config", systemImage: "doc.text.fill")
                .font(.system(size: 14, weight: .semibold))
            Text("""
            We'll inject one sentinel-guarded `Include` line at the top of your \
            `~/.ssh/config`. This makes Bastion-managed hosts visible to every \
            other tool that reads that file (scp, rsync, mosh, git, VSCode Remote-SSH).
            """)
            .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Diff preview (added to top of ~/.ssh/config):")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text("""
                    \(Paths.includeBlockBegin) — do not edit. Remove the whole block to uninstall Bastion.
                    \(Paths.includeDirective)
                    \(Paths.includeBlockEnd)
                    """)
                    .font(.caption.monospaced())
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .frame(minHeight: 80, maxHeight: 120)
            }
            if model.includeInstalled {
                Label("Include block installed.", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        }
    }
}

struct ControlMasterScreen: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Keep SSH connections alive (ControlMaster)", systemImage: "link")
                .font(.system(size: 14, weight: .semibold))
            Text("""
            ControlMaster reuses one SSH connection across many sessions. New tabs to the same host \
            open instantly with no auth prompt — once you've authenticated once per work-day, \
            subsequent connects are zero-friction. You can override per host later.
            """)
            .font(.caption).foregroundStyle(.secondary)

            Toggle("Enable ControlMaster for all imported hosts", isOn: $model.enableControlMasterDefault)
            if model.enableControlMasterDefault {
                HStack {
                    Text("Default persistence:")
                    Picker("", selection: $model.controlPersist) {
                        ForEach(ControlPersistChoice.presets, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                .font(.caption)
                Text("8 hours matches a standard work-day — re-authenticate once per morning.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct LoginItemScreen: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var loginItem: LoginItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Open Bastion at login", systemImage: "power")
                .font(.system(size: 14, weight: .semibold))
            Text("""
            Keep Bastion in your menu bar across reboots so master connections re-establish \
            automatically. (You can toggle this any time in System Settings → General → Login Items.)
            """)
            .font(.caption).foregroundStyle(.secondary)

            Toggle("Open at login", isOn: Binding(
                get: { model.openAtLogin },
                set: { newValue in
                    model.openAtLogin = newValue
                    let result = loginItem.setEnabled(newValue)
                    switch result {
                    case .requiresMove:
                        model.lastError = "Move Bastion to /Applications first (Step 2)."
                    case .requiresApproval:
                        loginItem.openLoginItemsSettings()
                    case .failed(let e):
                        model.lastError = "Login item: \(e.localizedDescription)"
                    case .ok:
                        model.lastError = nil
                    }
                }
            ))
            Text("Current status: \(loginItem.statusDescription)")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct NotificationsScreen: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var notifications: NotificationPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Notifications", systemImage: "bell.badge")
                .font(.system(size: 14, weight: .semibold))
            Text("""
            Bastion only notifies you on genuine failures: a ControlMaster drops unexpectedly, a \
            stored SSH cert is about to expire, or the user's Keychain locks while a key passphrase \
            is held. Never on routine connects or disconnects.
            """)
            .font(.caption).foregroundStyle(.secondary)

            Toggle("Allow notifications", isOn: Binding(
                get: { model.enableNotifications },
                set: { newValue in
                    model.enableNotifications = newValue
                    if newValue {
                        Task { _ = await notifications.requestAuthorization() }
                    }
                }
            ))
        }
    }
}

struct DoneScreen: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("All set", systemImage: "checkmark.seal.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                summaryLine("Default terminal", model.selectedTerminal?.displayName ?? "—")
                summaryLine("Imported hosts", "\(model.importSelections.count)")
                summaryLine("Include block", model.includeInstalled ? "Installed" : "Skipped")
                summaryLine("ControlMaster default", model.enableControlMasterDefault ? "On (\(model.controlPersist.displayName))" : "Off")
                summaryLine("Open at login", model.openAtLogin ? "Enabled" : "Off")
                summaryLine("Notifications", model.enableNotifications ? "Enabled" : "Off")
            }
            Text("Click Bastion in your menu bar to start managing hosts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func summaryLine(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
            Text(v).font(.caption.weight(.medium))
            Spacer()
        }
    }
}
