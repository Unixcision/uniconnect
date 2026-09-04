import SwiftUI

/// Compact recovery affordance shown when a local shell stopped or a saved resume was declined.
struct UniConnectLocalWindowRecoveryBanner: View {
    let snapshot: UniConnectLocalWindowActionMenuSnapshot
    let onPerform: (UniConnectLocalWindowAction) -> Void

    var body: some View {
        if let preferredAction = snapshot.preferredRecoveryAction {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                    Image(systemName: preferredAction.systemImageName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.runtimeTitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(snapshot.runtimeDetail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 6)

                Button(preferredAction.title) {
                    onPerform(preferredAction.action)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!preferredAction.isEnabled)

                Menu {
                    UniConnectLocalWindowActionMenu(
                        snapshot: snapshot,
                        onPerform: onPerform
                    )
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 16, height: 16)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(
                    String(
                        localized: "uniconnect.localWindow.menu.moreActions",
                        defaultValue: "More Window Actions"
                    )
                )
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("UniConnectLocalWindowRecoveryBanner")
        }
    }
}
