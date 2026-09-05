import SwiftUI

/// Direct-IP setup and local approval UI; rows receive values and action closures only.
@MainActor
struct UniConnectMobileAccessView: View {
    let model: UniConnectMobileAccessViewModel

    var body: some View {
        // Snapshot collections above the list boundary; no row observes a store.
        let pending = model.access.pendingPeers
        let approved = model.access.approvedPeers
        let isSaving = model.access.isSaving
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(
                    String(localized: "uniconnect.mobile.access.title", defaultValue: "Acceso remoto"),
                    systemImage: "network"
                )
                .font(.title2.weight(.semibold))

                Text(String(
                    localized: "uniconnect.mobile.access.explanation",
                    defaultValue: "Conecta UniConnect en Android a la IP de Tailscale de este Mac. Autoriza aquí el dispositivo: no necesitas otra cuenta."
                ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                connectionSection

                if let error = model.access.lastError ?? model.errorMessage {
                    Text(error).foregroundStyle(.orange)
                        .textSelection(.enabled)
                }

                Divider()
                Text(String(localized: "uniconnect.mobile.access.pending", defaultValue: "Solicitudes pendientes"))
                    .font(.headline)
                if pending.isEmpty {
                    Text(String(
                        localized: "uniconnect.mobile.access.noPending",
                        defaultValue: "Cuando un dispositivo intente conectar, su solicitud aparecerá aquí."
                    ))
                    .foregroundStyle(.secondary)
                }
                ForEach(pending) { peer in
                    VStack(alignment: .leading, spacing: 8) {
                        peerLabel(address: peer.address, label: peer.label)
                        HStack {
                            Button(String(localized: "uniconnect.mobile.access.reject", defaultValue: "Rechazar")) {
                                model.access.reject(address: peer.address)
                            }
                            .disabled(isSaving)
                            Button(String(localized: "uniconnect.mobile.access.approve", defaultValue: "Autorizar dispositivo")) {
                                Task { await model.access.approve(address: peer.address) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isSaving)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }

                Divider()
                Text(String(localized: "uniconnect.mobile.access.approved", defaultValue: "Dispositivos autorizados"))
                    .font(.headline)
                if approved.isEmpty {
                    Text(String(localized: "uniconnect.mobile.access.noApproved", defaultValue: "Todavía no has autorizado ningún dispositivo."))
                        .foregroundStyle(.secondary)
                }
                ForEach(approved) { peer in
                    HStack {
                        peerLabel(address: peer.address, label: peer.label)
                        Spacer(minLength: 16)
                        Button(String(localized: "uniconnect.mobile.access.revoke", defaultValue: "Revocar"), role: .destructive) {
                            Task { await model.access.revoke(address: peer.address) }
                        }
                        .disabled(isSaving)
                    }
                }

                Text(String(
                    localized: "uniconnect.mobile.access.scope",
                    defaultValue: "La autorización permite controlar los espacios y terminales desde esa máquina de Tailscale. Revocarla desconecta su acceso. No se comparte la contraseña del Mac ni las claves SSH."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.observe() }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isRunning {
                Label(String(localized: "uniconnect.mobile.access.ready", defaultValue: "Acceso privado activo"), systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                ForEach(model.endpoints, id: \.self) { endpoint in
                    Text(endpoint).font(.body.monospaced()).textSelection(.enabled)
                }
            } else {
                Button(String(localized: "uniconnect.mobile.access.enable", defaultValue: "Activar acceso por Tailscale")) {
                    Task { await model.enable() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }
        }
    }

    private func peerLabel(address: String, label: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label, !label.isEmpty { Text(label).font(.body.weight(.medium)) }
            Text(address).font(.body.monospaced()).textSelection(.enabled)
        }
    }
}
