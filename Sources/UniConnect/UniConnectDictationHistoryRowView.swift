import SwiftUI

/// One dictation in the box's history: when, how long, where it was pasted, its text, and what can
/// be done with it.
///
/// It receives a value snapshot and closures only (the list's snapshot boundary), never the model.
struct UniConnectDictationHistoryRowView: View {
    /// What a row can ask for, by entry id or text.
    struct Actions {
        let paste: (String) -> Void
        let pasteAndSend: (String) -> Void
        let copy: (String) -> Void
        let togglePlayback: (String) -> Void
        let retranscribe: (String) -> Void
        let delete: (String) -> Void
    }

    let record: UniConnectDictationRecord
    let isPlaying: Bool
    let isRetranscribing: Bool
    let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                stateBadge
            }
            if let text = record.text {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(8)
            } else {
                Text(placeholder)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .italic()
            }
            HStack(spacing: 12) {
                if let text = record.text {
                    Button(String(localized: "uniconnect.dictation.paste.short", defaultValue: "Pegar")) {
                        actions.paste(text)
                    }
                    .help(String(localized: "uniconnect.dictation.paste.help", defaultValue: "Pegar en la terminal enfocada, sin Enter"))
                    Button {
                        actions.pasteAndSend(text)
                    } label: {
                        Image(systemName: "paperplane")
                    }
                    .help(String(localized: "uniconnect.dictation.pasteAndSend.help", defaultValue: "Pegar en la terminal enfocada y pulsar Enter"))
                    Button {
                        actions.copy(text)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help(String(localized: "uniconnect.dictation.copy", defaultValue: "Copiar"))
                }
                if record.audioFile != nil {
                    Button {
                        actions.togglePlayback(record.id)
                    } label: {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    }
                    .help(isPlaying
                        ? String(localized: "uniconnect.dictation.stopAudio", defaultValue: "Parar")
                        : String(localized: "uniconnect.dictation.playAudio", defaultValue: "Escuchar"))
                    if isRetranscribing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button {
                            actions.retranscribe(record.id)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(record.state == .transcribing)
                        .help(String(localized: "uniconnect.dictation.retranscribe", defaultValue: "Volver a transcribir"))
                    }
                } else {
                    Text(String(localized: "uniconnect.dictation.noAudio", defaultValue: "Sin audio"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Button {
                    actions.delete(record.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help(String(localized: "uniconnect.dictation.delete", defaultValue: "Borrar el dictado y su audio"))
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var summary: String {
        var parts = [Self.when(record.createdAt), UniConnectDictationClock(seconds: record.seconds).text]
        if let pastedInto = record.pastedInto {
            let format = String(localized: "uniconnect.dictation.pastedInto", defaultValue: "en %@")
            parts.append(String(format: format, pastedInto))
        }
        return parts.joined(separator: " · ")
    }

    private var placeholder: String {
        switch record.state {
        case .transcribing:
            return String(localized: "uniconnect.dictation.state.transcribing", defaultValue: "Transcribiendo…")
        case .done, .unread:
            return String(localized: "uniconnect.dictation.state.unread", defaultValue: "Sin transcribir: escúchalo o vuelve a transcribirlo")
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        if record.state == .unread {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .help(String(localized: "uniconnect.dictation.state.unreadHelp", defaultValue: "Whisper no pudo leerlo"))
        } else if record.state == .transcribing {
            ProgressView().controlSize(.mini)
        }
    }

    /// «Hoy, 18:42», «Ayer, 09:10» or «3 nov, 18:42».
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "es_ES")))
        if calendar.isDate(date, inSameDayAs: now) {
            let format = String(localized: "uniconnect.dictation.today", defaultValue: "Hoy, %@")
            return String(format: format, time)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            let format = String(localized: "uniconnect.dictation.yesterday", defaultValue: "Ayer, %@")
            return String(format: format, time)
        }
        let day = date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "es_ES")))
        return "\(day), \(time)"
    }
}
