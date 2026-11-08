import SwiftUI

/// «Ejecutar como» in the desktop's new-window sheets, local and SSH (`run-as.v1`).
///
/// Offers the same choices as the phone: my user, root or another user, `sudo` or `su`, the
/// password to switch, and `IS_SANDBOX=1`, ticked by default when root is chosen and locked on
/// for Claude as root, which cannot start without prompts otherwise. The password stays in this
/// view's state until the sheet hands it to the creation; it is never displayed.
struct UniConnectRunAsFields: View {
    @Binding var mode: UniConnectRunAs.Mode
    @Binding var method: UniConnectRunAs.Method
    @Binding var user: String
    @Binding var password: String
    @Binding var isSandbox: Bool
    /// Claude as root: `IS_SANDBOX=1` is applied whatever the box says.
    var sandboxForced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "uniconnect.runAs.title", defaultValue: "Ejecutar como"))
                .font(.system(size: 11.5, weight: .semibold))
            Picker("", selection: $mode) {
                Text(String(localized: "uniconnect.runAs.mode.current", defaultValue: "Mi usuario")).tag(UniConnectRunAs.Mode.current)
                Text(String(localized: "uniconnect.runAs.mode.root", defaultValue: "root")).tag(UniConnectRunAs.Mode.root)
                Text(String(localized: "uniconnect.runAs.mode.user", defaultValue: "Otro usuario")).tag(UniConnectRunAs.Mode.user)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: mode) { _, newMode in
                isSandbox = newMode == .root
            }
            if mode != .current {
                Picker("", selection: $method) {
                    Text(String(localized: "uniconnect.runAs.method.sudo", defaultValue: "sudo (tu contraseña)")).tag(UniConnectRunAs.Method.sudo)
                    Text(String(localized: "uniconnect.runAs.method.su", defaultValue: "su (contraseña del destino)")).tag(UniConnectRunAs.Method.su)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if mode == .user {
                    TextField(String(localized: "uniconnect.runAs.user", defaultValue: "Usuario"), text: $user)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
                SecureField(
                    String(localized: "uniconnect.runAs.password", defaultValue: "Contraseña (vacía si no la pide)"),
                    text: $password
                )
                .textFieldStyle(.roundedBorder)
            }
            Toggle(
                String(localized: "uniconnect.runAs.sandbox", defaultValue: "IS_SANDBOX=1"),
                isOn: sandboxForced ? .constant(true) : $isSandbox
            )
            .toggleStyle(.checkbox)
            .disabled(sandboxForced)
            if sandboxForced {
                Text(String(
                    localized: "uniconnect.runAs.sandbox.forced",
                    defaultValue: "Claude como root solo arranca sin preguntas con IS_SANDBOX=1, así que va siempre."
                ))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(String(
                localized: "uniconnect.runAs.hint",
                defaultValue: "La IA arranca sin preguntas. La contraseña se guarda cifrada con la ventana y se borra al cerrarla."
            ))
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The choice as a request value, or `nil` when "Otro usuario" has no valid name.
    static func runAs(mode: UniConnectRunAs.Mode, method: UniConnectRunAs.Method, user: String) -> UniConnectRunAs? {
        UniConnectRunAs(mode: mode, method: method, user: user.trimmingCharacters(in: .whitespaces))
    }
}
