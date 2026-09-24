import AppKit
import SwiftUI

/// The «Detalles» modal of one window: workspace, window, tmux and agent, with the resume command.
///
/// It opens at once with what is saved and a «Comprobando…» mark, and updates when the live
/// reading arrives; if that fails it says so and keeps showing what was saved. Every text comes from
/// ``UniConnectWindowDetailsRows``, the literal rows of `contracts/window-details-v1`.
struct UniConnectWindowDetailsView: View {
    let model: UniConnectWindowDetailsModel
    let onClose: () -> Void
    @State private var copied = false

    private var rows: UniConnectWindowDetailsRows { UniConnectWindowDetailsRows(snapshot: model.snapshot) }

    /// Rows whose values are identifiers or paths, shown monospaced.
    private static let monospacedLabels: Set<String> = [
        String(localized: "uniconnect.windowDetails.row.tmuxSession", defaultValue: "Sesión tmux"),
        String(localized: "uniconnect.windowDetails.row.conversation", defaultValue: "ID de conversación"),
        String(localized: "uniconnect.windowDetails.row.folder", defaultValue: "Carpeta"),
    ]

    var body: some View {
        let rows = self.rows
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "uniconnect.windowDetails.title", defaultValue: "Detalles de la ventana"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if model.checking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "uniconnect.windowDetails.checking", defaultValue: "Comprobando…"))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            if !model.checking, let notice = rows.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            ScrollView {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(Array(rows.rows.enumerated()), id: \.offset) { entry in
                        GridRow {
                            Text(entry.element.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            Text(entry.element.value)
                                .font(Self.monospacedLabels.contains(entry.element.label)
                                    ? .system(size: 12, design: .monospaced)
                                    : .system(size: 12))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let command = rows.resumeCommand {
                VStack(alignment: .leading, spacing: 6) {
                    Text(rows.resumeLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                    if let note = rows.resumeNote {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
            }
            HStack {
                if copied {
                    Text(String(localized: "uniconnect.windowDetails.copied", defaultValue: "Orden copiada"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let command = rows.resumeCommand {
                    Button(String(localized: "uniconnect.windowDetails.copy", defaultValue: "Copiar orden")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    }
                }
                Button(String(localized: "uniconnect.windowDetails.close", defaultValue: "Cerrar"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
    }
}
