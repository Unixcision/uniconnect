import SwiftUI

/// One window in «Cuentas de IA»: name, provider, account in its color, plan, user and file.
///
/// Receives only values (no model), so typing in the search field never re-renders every row.
struct UniConnectAccountsRowView: View {
    let window: UniConnectAccountsSnapshot.Window
    /// The host label, shown when rows are grouped by account.
    let hostLabel: String?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            providerBadge
                .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: window.window)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            accountView
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        if let hostLabel { parts.append("\(window.workspace) · \(hostLabel)") }
        if let user = window.account?.osUser { parts.append(user) }
        if let config = window.account?.config { parts.append(config) }
        if parts.isEmpty, let session = window.tmuxSession { parts.append("tmux \(session)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var providerBadge: some View {
        if let agent = window.agent {
            Text(verbatim: agent.displayName)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                .lineLimit(1)
        } else {
            Text(verbatim: "—")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var accountView: some View {
        if window.state == .ok, let email = window.account?.email {
            HStack(spacing: 8) {
                Circle()
                    .fill(UniConnectAccountsPalette.color(email: email))
                    .frame(width: 8, height: 8)
                Text(verbatim: email)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(UniConnectAccountsPalette.color(email: email))
                    .lineLimit(1)
                    .textSelection(.enabled)
                if let plan = window.account?.plan {
                    Text(verbatim: plan)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(verbatim: Self.stateText(window))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(window.state == .noSession ? Color.orange : Color.secondary)
                .lineLimit(1)
        }
    }

    /// The gray text for a window without an email (§4).
    static func stateText(_ window: UniConnectAccountsSnapshot.Window) -> String {
        switch window.state {
        case .ok:
            switch window.account?.method {
            case "api_key": return String(localized: "uniconnect.accounts.method.apiKey", defaultValue: "Clave de API")
            case "bedrock": return "Bedrock"
            case "vertex": return "Vertex"
            case "foundry": return "Foundry"
            default: return String(localized: "uniconnect.accounts.state.unknown", defaultValue: "Cuenta no expuesta")
            }
        case .noSession:
            return String(localized: "uniconnect.accounts.state.noSession", defaultValue: "Sin sesión")
        case .unreadable:
            if let user = window.account?.osUser {
                let format = String(localized: "uniconnect.accounts.state.unreadableAs", defaultValue: "No legible como %@")
                return String(format: format, user)
            }
            return String(localized: "uniconnect.accounts.state.unreadable", defaultValue: "No legible")
        case .unknown:
            return String(localized: "uniconnect.accounts.state.unknown", defaultValue: "Cuenta no expuesta")
        case .noAgent:
            return String(localized: "uniconnect.accounts.state.noAgent", defaultValue: "Sin IA")
        case .ambiguous:
            return String(localized: "uniconnect.accounts.state.ambiguous", defaultValue: "Varias IA en la ventana")
        case .deadPane:
            return String(localized: "uniconnect.accounts.state.deadPane", defaultValue: "Panel cerrado")
        case .hostUnreachable:
            return String(localized: "uniconnect.accounts.state.hostUnreachable", defaultValue: "Host sin respuesta")
        case .noTmux:
            return String(localized: "uniconnect.accounts.state.noTmux", defaultValue: "Sin tmux")
        case .sessionNotLive:
            return String(localized: "uniconnect.accounts.state.sessionNotLive", defaultValue: "La sesión tmux no está viva")
        }
    }
}
