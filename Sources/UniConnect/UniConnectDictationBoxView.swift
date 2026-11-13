import SwiftUI

/// «Dictado»'s box: record, see what Whisper understood, paste it or copy it, and the history.
struct UniConnectDictationBoxView: View {
    @Bindable var model: UniConnectDictationModel
    /// The floating button's place, for the side the «esconder» arrow points to.
    let bubble: UniConnectDictationBubbleState
    let onClose: () -> Void
    let onDock: () -> Void
    let onOpenMicrophoneSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            recorder
            if let notice = model.notice {
                noticeView(notice)
            }
            if model.lastRecordID != nil {
                lastDictation
            }
            Divider()
            history
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The header sits where a title bar would be: its empty space drags the window.
        .ignoresSafeArea(.container, edges: .top)
        .background(.regularMaterial)
        .task { await model.loadHistory() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label(String(localized: "uniconnect.dictation.title", defaultValue: "Dictado"), systemImage: "waveform")
                .font(.headline)
                .help(String(localized: "uniconnect.dictation.moveHint", defaultValue: "Arrastra desde aquí para mover la caja; los bordes la agrandan o la encogen"))
            Spacer()
            Menu {
                Picker(String(localized: "uniconnect.dictation.language", defaultValue: "Idioma"), selection: $model.language) {
                    ForEach(UniConnectDictationLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "uniconnect.dictation.options.language", defaultValue: "Idioma"))
            Button(action: onDock) {
                Image(systemName: bubble.layout.edge == .right ? "chevron.right.to.line" : "chevron.left.to.line")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "uniconnect.dictation.dock", defaultValue: "Esconder el botón en el borde"))
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help(String(localized: "uniconnect.dictation.close", defaultValue: "Cerrar"))
        }
    }

    private var recorder: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                Task { await model.toggleRecording() }
            } label: {
                ZStack {
                    Circle().fill((model.isRecording ? Color.red : Color.accentColor).gradient)
                    Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 64, height: 64)
            }
            .buttonStyle(.plain)
            .disabled(model.isTranscribing || model.phase == .requestingAccess)
            .help(model.isRecording
                ? String(localized: "uniconnect.dictation.stop", defaultValue: "Terminar y transcribir")
                : String(localized: "uniconnect.dictation.record", defaultValue: "Grabar"))

            VStack(alignment: .leading, spacing: 6) {
                Text(status)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isRecording {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        let meter = model.meter()
                        HStack(spacing: 8) {
                            Text(UniConnectDictationClock(seconds: meter.seconds).text)
                                .font(.callout.monospacedDigit())
                            UniConnectDictationLevelBar(level: meter.level)
                                .frame(height: 6)
                        }
                    }
                    Button(String(localized: "uniconnect.dictation.discard", defaultValue: "Descartar")) {
                        model.cancelRecording()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                } else if model.isTranscribing || model.phase == .requestingAccess {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
        }
    }

    private var status: String {
        switch model.phase {
        case .idle:
            return String(localized: "uniconnect.dictation.status.idle", defaultValue: "Pulsa para grabar. Lo transcribe Whisper en este Mac.")
        case .requestingAccess:
            return String(localized: "uniconnect.dictation.status.access", defaultValue: "Esperando el permiso del micrófono…")
        case .recording:
            return String(localized: "uniconnect.dictation.status.recording", defaultValue: "Grabando… pulsa para terminar (máx. 15 min).")
        case .transcribing:
            return String(localized: "uniconnect.dictation.status.transcribing", defaultValue: "Transcribiendo con Whisper…")
        }
    }

    @ViewBuilder
    private func noticeView(_ notice: UniConnectDictationModel.Notice) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: Self.symbol(for: notice))
                .foregroundStyle(Self.color(for: notice))
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.text(for: notice))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if notice == .microphoneDenied {
                    Button(String(localized: "uniconnect.dictation.openMicrophoneSettings", defaultValue: "Abrir Ajustes del Sistema")) {
                        onOpenMicrophoneSettings()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            Spacer(minLength: 0)
            Button {
                model.dismissNotice()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
        }
    }

    private var lastDictation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "uniconnect.dictation.last", defaultValue: "Último dictado"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.lastText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .disabled(model.isTranscribing)
                if model.lastText.isEmpty {
                    Text(model.isTranscribing
                        ? String(localized: "uniconnect.dictation.state.transcribing", defaultValue: "Transcribiendo…")
                        : String(localized: "uniconnect.dictation.last.empty", defaultValue: "Sin texto"))
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .frame(height: 88)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            HStack(spacing: 8) {
                if model.lastWasPasted {
                    Button {
                        Task { await model.sendLast() }
                    } label: {
                        Label(String(localized: "uniconnect.dictation.send", defaultValue: "Enviar"), systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .help(String(localized: "uniconnect.dictation.send.help", defaultValue: "Ya está pegado en la terminal: pulsa Enter allí, sin pegarlo otra vez"))
                    Button(String(localized: "uniconnect.dictation.pasteAgain", defaultValue: "Pegar otra vez")) {
                        Task { await model.paste(model.lastText) }
                    }
                    .help(String(localized: "uniconnect.dictation.pasteAgain.help.v2", defaultValue: "Ya está pegado; esto lo pega de nuevo en la terminal enfocada"))
                } else {
                    Button(String(localized: "uniconnect.dictation.paste.short", defaultValue: "Pegar")) {
                        Task { await model.paste(model.lastText) }
                    }
                    .buttonStyle(.borderedProminent)
                    .help(String(localized: "uniconnect.dictation.paste.help", defaultValue: "Pegar en la terminal enfocada, sin Enter"))
                    Button {
                        Task { await model.pasteAndSend(model.lastText) }
                    } label: {
                        Label(String(localized: "uniconnect.dictation.pasteAndSend", defaultValue: "Pegar y enviar"), systemImage: "paperplane")
                    }
                    .help(String(localized: "uniconnect.dictation.pasteAndSend.help", defaultValue: "Pegar en la terminal enfocada y pulsar Enter"))
                }
                Button(String(localized: "uniconnect.dictation.copy", defaultValue: "Copiar")) {
                    model.copy(model.lastText)
                }
                Spacer()
            }
            .disabled(model.lastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var history: some View {
        let shown = model.shownRecords
        let actions = UniConnectDictationHistoryRowView.Actions(
            paste: { text in Task { await model.paste(text) } },
            pasteAndSend: { text in Task { await model.pasteAndSend(text) } },
            copy: { model.copy($0) },
            togglePlayback: { model.togglePlayback($0) },
            retranscribe: { id in Task { await model.retranscribe(id) } },
            delete: { id in Task { await model.delete(id) } }
        )
        let playingID = model.playingID
        let retranscribing = model.retranscribing
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "uniconnect.dictation.history", defaultValue: "Historial"))
                    .font(.headline)
                Text(historyNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            TextField(
                String(localized: "uniconnect.dictation.search", defaultValue: "Buscar en el historial"),
                text: $model.query
            )
            .textFieldStyle(.roundedBorder)
            if shown.isEmpty {
                Text(model.records.isEmpty
                    ? String(localized: "uniconnect.dictation.history.empty", defaultValue: "Aquí quedan tus dictados, con su texto y su audio.")
                    : String(localized: "uniconnect.dictation.history.noMatch", defaultValue: "Ningún dictado coincide con la búsqueda."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(shown) { record in
                            UniConnectDictationHistoryRowView(
                                record: record,
                                isPlaying: playingID == record.id,
                                isRetranscribing: retranscribing.contains(record.id),
                                actions: actions
                            )
                        }
                    }
                }
            }
        }
    }

    private var historyNote: String {
        let size = ByteCountFormatter.string(fromByteCount: model.keptAudioBytes, countStyle: .file)
        if model.records.count == 1 {
            let format = String(localized: "uniconnect.dictation.history.note.one", defaultValue: "1 dictado · %@ de audio")
            return String(format: format, size)
        }
        let format = String(localized: "uniconnect.dictation.history.note", defaultValue: "%1$lld dictados · %2$@ de audio")
        return String.localizedStringWithFormat(format, Int64(model.records.count), size)
    }

    private static func symbol(for notice: UniConnectDictationModel.Notice) -> String {
        switch notice {
        case .pasted, .copied: return "checkmark.circle.fill"
        case .sent: return "paperplane.circle.fill"
        case .cut, .tooShort, .noTerminal: return "info.circle.fill"
        case .notUnderstood, .microphoneDenied, .failed: return "exclamationmark.triangle.fill"
        }
    }

    private static func color(for notice: UniConnectDictationModel.Notice) -> Color {
        switch notice {
        case .pasted, .copied, .sent: return .green
        case .cut, .tooShort, .noTerminal: return .secondary
        case .notUnderstood, .microphoneDenied, .failed: return .orange
        }
    }

    private static func text(for notice: UniConnectDictationModel.Notice) -> String {
        switch notice {
        case .pasted(let name):
            let format = String(localized: "uniconnect.dictation.notice.pasted", defaultValue: "Pegado en «%@», sin Enter.")
            return String(format: format, name)
        case .sent(let name):
            let format = String(localized: "uniconnect.dictation.notice.sent", defaultValue: "Enviado en «%@».")
            return String(format: format, name)
        case .copied:
            return String(localized: "uniconnect.dictation.notice.copied", defaultValue: "Copiado.")
        case .noTerminal:
            return String(localized: "uniconnect.dictation.notice.noTerminal", defaultValue: "No hay ninguna terminal enfocada: el texto queda aquí y en el historial.")
        case .microphoneDenied:
            return String(localized: "uniconnect.dictation.notice.microphoneDenied", defaultValue: "UniConnect no tiene permiso para usar el micrófono. Actívalo en Ajustes del Sistema › Privacidad y seguridad › Micrófono.")
        case .cut:
            return String(localized: "uniconnect.dictation.notice.cut", defaultValue: "La grabación llegó a los 15 minutos y se paró sola.")
        case .notUnderstood:
            return String(localized: "uniconnect.dictation.notice.notUnderstood", defaultValue: "Whisper no entendió nada. El audio queda en el historial.")
        case .tooShort:
            return String(localized: "uniconnect.dictation.notice.tooShort", defaultValue: "Grabación demasiado corta; no se guardó.")
        case .failed(let message):
            return message
        }
    }
}
