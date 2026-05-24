import SwiftUI
import BastionCore

/// Tab identifier for the host editor.
enum EditorTab: String, CaseIterable, Identifiable {
    case basic, advanced, raw
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .basic:    return "Basic"
        case .advanced: return "Advanced"
        case .raw:      return "Raw"
        }
    }
}

/// Full SwiftUI host editor. Three tabs: Basic (always-visible fields),
/// Advanced (collapsible options grid), Raw (free-form text + post-save
/// `ssh -G` validation).
struct HostEditorView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Binding var draft: ManagedHost
    @State private var tab: EditorTab = .basic
    @State private var validationMessage: String?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var renameWarning: String?
    let originalAlias: String?
    let onSaved: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(EditorTab.allCases) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14).padding(.top, 8)
            Group {
                switch tab {
                case .basic:    BasicTab(draft: $draft, coordinator: coordinator)
                case .advanced: AdvancedTab(draft: $draft)
                case .raw:      RawTab(draft: $draft, validationMessage: $validationMessage)
                }
            }
            .padding(14)
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .frame(width: 480, height: 540)
        .onChange(of: draft.alias) { newValue in
            if let original = originalAlias, original != newValue {
                renameWarning = """
                Renaming this alias will break any external references — git remotes \
                (\(original):repo.git), VS Code Remote-SSH workspaces, Ansible inventories. \
                Consider keeping the old name as a synonym for one release.
                """
            } else {
                renameWarning = nil
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var header: some View {
        HStack {
            Text(originalAlias == nil ? "New Host" : "Edit \(originalAlias!)")
                .font(.headline)
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.escape)
            Button("Save", action: save)
                .keyboardShortcut(.return)
                .disabled(isSaving || !Alias.isValid(draft.alias) || draft.hostname.isEmpty)
        }
        .padding(14)
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let renameWarning {
                Label(renameWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let validationMessage {
                Label(validationMessage, systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let saveError {
                Label(saveError, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        Task {
            isSaving = true
            saveError = nil
            do {
                let result = try await coordinator.engine.upsertHost(draft)
                if !result.integrationPassed {
                    validationMessage = "Saved, but ssh -G reported effective-config mismatches — \(result.integrationMismatches.keys.joined(separator: ", "))"
                } else {
                    validationMessage = "Saved and ssh -G validated."
                }
                _ = await coordinator.refreshNow()
                onSaved()
            } catch {
                saveError = "\(error)"
            }
            isSaving = false
        }
    }
}

// MARK: - Basic tab

struct BasicTab: View {
    @Binding var draft: ManagedHost
    @ObservedObject var coordinator: AppCoordinator
    @State private var newIdentityPath: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FormField("Alias") {
                    TextField("", text: $draft.alias).textFieldStyle(.roundedBorder)
                }
                if !Alias.isValid(draft.alias) {
                    Label("Alias must match \(Alias.pattern)", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                FormField("Hostname") {
                    TextField("prod-db.example.com", text: $draft.hostname).textFieldStyle(.roundedBorder)
                }
                FormField("User") {
                    TextField("dan", text: Binding(
                        get: { draft.user ?? "" },
                        set: { draft.user = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                FormField("Port") {
                    TextField("22", value: $draft.port, formatter: portFormatter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                identityFilesSection
                controlMasterSection
                tagsSection
            }
        }
    }

    @ViewBuilder
    private var identityFilesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Identity files")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(draft.identityFiles.enumerated()), id: \.offset) { index, path in
                HStack {
                    Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(role: .destructive) {
                        draft.identityFiles.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("~/.ssh/<key>", text: $newIdentityPath).textFieldStyle(.roundedBorder)
                Button("Add") {
                    let trimmed = newIdentityPath.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    draft.identityFiles.append(trimmed)
                    newIdentityPath = ""
                }
                .disabled(newIdentityPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var controlMasterSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ControlMaster (keepalive)")
                .font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $draft.controlMaster) {
                Text("Inherit").tag(ControlMasterChoice.inherit)
                Text("On").tag(ControlMasterChoice.on)
                Text("Off").tag(ControlMasterChoice.off)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if draft.controlMaster != .off {
                HStack {
                    Text("Persist").font(.caption).foregroundStyle(.secondary)
                    Picker("Persist", selection: $draft.controlPersist) {
                        Text("Inherit").tag(ControlPersistChoice.inherit)
                        ForEach(ControlPersistChoice.presets, id: \.self) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags (filter chips)").font(.caption).foregroundStyle(.secondary)
            TextField("comma,separated", text: Binding(
                get: { draft.tags.joined(separator: ",") },
                set: { draft.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }

    private var portFormatter: NumberFormatter {
        let f = NumberFormatter(); f.allowsFloats = false; f.minimum = 1; f.maximum = 65535
        return f
    }
}

// MARK: - Advanced tab

struct AdvancedTab: View {
    @Binding var draft: ManagedHost

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Free-form key=value for every option we don't surface in Basic. Each row writes one `<Key> <Value>` line in your managed config.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(advancedOptionsList.enumerated()), id: \.offset) { index, option in
                    HStack {
                        Text(option.configKey)
                            .font(.caption.monospaced())
                            .frame(width: 180, alignment: .leading)
                        TextField("", text: Binding(
                            get: { draft.advanced[option] ?? "" },
                            set: { newValue in
                                if newValue.isEmpty {
                                    draft.advanced.removeValue(forKey: option)
                                } else {
                                    draft.advanced[option] = newValue
                                }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    /// Subset of SSHOption shown in the Advanced tab (Basic-tab options
    /// + auto-emitted options excluded).
    private var advancedOptionsList: [SSHOption] {
        let basicOrAuto: Set<SSHOption> = [
            .identityFile, .identitiesOnly,
            .controlMaster, .controlPath, .controlPersist,
            .tag
        ]
        return SSHOption.allCases.filter { !basicOrAuto.contains($0) }
            .sorted { $0.configKey < $1.configKey }
    }
}

// MARK: - Raw tab

struct RawTab: View {
    @Binding var draft: ManagedHost
    @Binding var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Raw lines appended verbatim to this host's stanza. Validated by `ssh -G` on save.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { draft.rawConfigOverride ?? "" },
                set: { draft.rawConfigOverride = $0.isEmpty ? nil : $0 }
            ))
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: 200)
            .padding(4)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.tertiary))
        }
    }
}

// MARK: - Helpers

struct FormField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}
