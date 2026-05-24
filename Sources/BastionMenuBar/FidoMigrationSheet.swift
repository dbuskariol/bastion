import SwiftUI
import BastionCore

/// One-time migration acknowledgement sheet for the FIDO/ControlMaster
/// interlock. Per dual-model consensus + rubber-duck pass: this
/// surfaces broken existing hosts (where `requiresInteractiveAuth==true`
/// but ControlMaster is disabled in effective config) and offers a
/// transparent three-way choice — never silently mutates user config.
///
/// Industry parallel: GitHub Desktop's "we migrated your X" dialogs;
/// `aws configure sso` migration prompts.
struct FidoMigrationSheet: View {
    let candidates: [HostSnapshot]
    let onFixAll: () -> Void
    let onReviewEach: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("FIDO hosts need ControlMaster")
                        .font(.headline)
                    Text("Bastion can fix this for you.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Found \(candidates.count) FIDO-auth host(s) configured without ControlMaster:")
                    .font(.callout)
                ForEach(candidates, id: \.id) { host in
                    HStack {
                        Image(systemName: "key.horizontal.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(host.alias).font(.callout.monospaced())
                        Text("(\(host.user.map { "\($0)@" } ?? "")\(host.hostname))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            Text("FIDO/SSO authentication requires a persistent master so you only touch the key once per ControlPersist window. Without it, every command would prompt for a new FIDO touch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Not now", action: onNotNow)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Review each", action: onReviewEach)
                Button(action: onFixAll) {
                    Label("Fix all (\(candidates.count))", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
