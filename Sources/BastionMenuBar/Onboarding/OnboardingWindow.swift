import Foundation
import SwiftUI
import BastionCore
import BastionIdentifiers

/// The nine canonical onboarding steps. Each maps to one screen in
/// OnboardingWindow.
enum OnboardingStep: Int, CaseIterable, Hashable {
    case welcome = 0
    case moveToApplications
    case chooseTerminal
    case importHosts
    case sshConfigIntegration
    case controlMasterDefault
    case openAtLogin
    case notifications
    case done

    var displayName: String {
        switch self {
        case .welcome:               return "Welcome"
        case .moveToApplications:    return "Move to /Applications"
        case .chooseTerminal:        return "Default terminal"
        case .importHosts:           return "Import existing hosts"
        case .sshConfigIntegration:  return "SSH config integration"
        case .controlMasterDefault:  return "ControlMaster default"
        case .openAtLogin:           return "Open at login"
        case .notifications:         return "Notifications"
        case .done:                  return "Done"
        }
    }
}

/// Reactive onboarding model. Owns the current step, the imported
/// candidates, and the user's running selections.
@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step: OnboardingStep = .welcome
    @Published var selectedTerminal: TerminalID?
    @Published var importCandidates: [ImportCandidate] = []
    @Published var importSelections: Set<ParsedConnection.DedupKey> = []
    @Published var importSortMode: ImportSortMode = .recent
    @Published var enableControlMasterDefault: Bool = false
    @Published var controlPersist: ControlPersistChoice = .hours(8)
    @Published var openAtLogin: Bool = false
    @Published var enableNotifications: Bool = false
    @Published var includeInstalled: Bool = false
    @Published var lastError: String?

    var canMoveToApplications: Bool { !AppRelocator.isAlreadyInApplications }

    func next() {
        if let nextStep = OnboardingStep(rawValue: step.rawValue + 1) {
            step = nextStep
        }
    }
    func previous() {
        if let prevStep = OnboardingStep(rawValue: step.rawValue - 1), prevStep.rawValue >= 0 {
            step = prevStep
        }
    }
}

/// Window-level container for the onboarding flow.
struct OnboardingWindow: View {
    @ObservedObject var coordinator: AppCoordinator
    @StateObject private var model = OnboardingModel()
    @StateObject private var loginItem = LoginItemController()
    @StateObject private var notifications = NotificationPermission()
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(20) }
                .frame(minHeight: 320)
            Divider()
            footer
        }
        .frame(width: 560, height: 540)
        .managesActivationPolicy(identifierPrefix: "bastion.setup")
        .onAppear {
            model.selectedTerminal = coordinator.defaultTerminal ?? coordinator.detector.suggestedDefault()
            Task {
                let registry = (try? coordinator.engine.loadRegistry()) ?? HostRegistry()
                let importer = ImportEngine(registry: registry)
                let candidates = importer.discover(sources: [.all])
                await MainActor.run {
                    model.importCandidates = candidates
                    // Pre-check candidates seen at least 3 times or in the
                    // last 30 days (rough "frequently used" heuristic).
                    let recent = Date().addingTimeInterval(-30 * 86_400)
                    model.importSelections = Set(candidates.filter {
                        !$0.alreadyManaged &&
                        ($0.invocationCount >= 3 || ($0.lastSeen ?? .distantPast) > recent)
                    }.map { $0.id })
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
            Text(model.step.displayName)
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text("Step \(model.step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome:              WelcomeScreen()
        case .moveToApplications:   MoveScreen(model: model)
        case .chooseTerminal:       TerminalScreen(model: model, coordinator: coordinator)
        case .importHosts:          ImportScreen(model: model)
        case .sshConfigIntegration: SSHConfigScreen(model: model, coordinator: coordinator)
        case .controlMasterDefault: ControlMasterScreen(model: model)
        case .openAtLogin:          LoginItemScreen(model: model, loginItem: loginItem)
        case .notifications:        NotificationsScreen(model: model, notifications: notifications)
        case .done:                 DoneScreen(model: model)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if let err = model.lastError {
                Label(err, systemImage: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            if model.step != .welcome && model.step != .done {
                Button("Back") { model.previous() }
            }
            switch model.step {
            case .welcome:
                Button("Get started") { model.next() }.buttonStyle(.borderedProminent)
            case .done:
                Button("Open Bastion") {
                    applyAll()
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
            case .sshConfigIntegration:
                Button("Apply Include") { applyInclude() }
                    .buttonStyle(.bordered)
                Button("Next") { model.next() }.buttonStyle(.borderedProminent)
            case .importHosts:
                Button("Skip") { model.next() }
                Button("Import \(model.importSelections.count) host\(model.importSelections.count == 1 ? "" : "s")") {
                    applySelectedImport()
                    model.next()
                }
                .buttonStyle(.borderedProminent)
            default:
                Button("Next") { model.next() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }

    // MARK: - Apply

    private func applyAll() {
        if let t = model.selectedTerminal { coordinator.setDefaultTerminal(t) }
        coordinator.preferences.notifyOnMasterDrop = model.enableNotifications
        coordinator.preferences.notifyOnCertExpiry = model.enableNotifications
    }

    private func applyInclude() {
        coordinator.installSSHConfigInclude()
        model.includeInstalled = true
    }

    private func applySelectedImport() {
        let chosen = model.importCandidates.filter { model.importSelections.contains($0.id) }
        Task {
            let cmChoice: ControlMasterChoice = model.enableControlMasterDefault ? .on : .inherit
            let persistChoice: ControlPersistChoice = model.enableControlMasterDefault ? model.controlPersist : .inherit
            _ = await coordinator.applyImportCandidates(chosen, controlMaster: cmChoice, controlPersist: persistChoice)
        }
    }
}
