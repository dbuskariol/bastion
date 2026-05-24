import SwiftUI

/// A primary action a warning popover can offer.
struct WarningAction {
    let label: String
    let action: () -> Void
}

/// Header warning icon that opens a popover with explanation + optional
/// action button. The icon itself is the trigger — click for detail,
/// hover for a short tooltip.
struct WarningButton: View {
    let icon: String
    let color: Color
    let title: String
    let message: String
    let primary: WarningAction?

    @State private var presenting = false

    var body: some View {
        Button(action: { presenting.toggle() }) {
            Image(systemName: icon)
                .foregroundStyle(color)
        }
        .buttonStyle(.borderless)
        .help(title)
        .popover(isPresented: $presenting, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundStyle(color)
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Dismiss") { presenting = false }
                        .keyboardShortcut(.escape)
                    Spacer()
                    if let primary {
                        Button(primary.label) {
                            primary.action()
                            presenting = false
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                    }
                }
                .font(.caption)
            }
            .padding(12)
            .frame(width: 320)
        }
    }
}
