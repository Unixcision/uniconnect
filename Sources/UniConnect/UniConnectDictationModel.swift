import Foundation
import Observation

/// State of «Dictado», the Mac's floating dictation box.
///
/// It records with the Mac's microphone, has the recording read by this Mac's Whisper (the same
/// engine and model that read the phone's dictations) and keeps every dictation in a history with
/// its audio. Stopping never pastes anything: the text waits in the box until the user presses
/// «Pegar» or «Pegar y enviar» (Dani's choice: an automatic paste on stop made him anxious).
/// The recording is kept before Whisper reads it, so nothing said is lost to a failure.
@MainActor
@Observable
final class UniConnectDictationModel {
    /// What the record button is doing.
    enum Phase: Equatable {
        case idle
        /// Waiting for macOS to answer the microphone permission.
        case requestingAccess
        case recording(startedAt: Date)
        /// Whisper is reading entry `recordID`.
        case transcribing(recordID: String)
    }

    /// The last thing that happened, shown once under the record button.
    enum Notice: Equatable {
        /// Pasted into the window with this name.
        case pasted(String)
        /// Sent (Enter pressed) in the window with this name.
        case sent(String)
        case copied
        /// There was no focused terminal to paste into; the text is in the box and the history.
        case noTerminal
        case microphoneDenied
        /// The recording reached the limit and stopped by itself.
        case cut
        /// Whisper heard nothing it could write.
        case notUnderstood
        /// Too short to be a dictation (a click by mistake); nothing was kept.
        case tooShort
        case failed(String)
    }

    private enum Keys {
        static let language = "uniconnect.dictation.language"
    }

    private(set) var phase: Phase = .idle
    private(set) var records: [UniConnectDictationRecord] = []
    /// Text of the last dictation, editable before pasting or copying it.
    var lastText = ""
    /// Entry of the last dictation, while it is in the history.
    private(set) var lastRecordID: String?
    /// Where the last dictation was pasted, so «Enviar» presses Enter there instead of pasting
    /// the same text a second time.
    private(set) var lastPasteTarget: UniConnectDictationTarget?
    private(set) var notice: Notice?
    /// Entries being read again.
    private(set) var retranscribing: Set<String> = []
    private(set) var playingID: String?
    var query = ""
    var language: UniConnectDictationLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    private let recorder: any UniConnectDictationRecording
    private let player: any UniConnectDictationPlaying
    private let transcriber: any UniConnectDictationTranscribing
    private let history: UniConnectDictationHistoryStore
    private let terminals: any UniConnectDictationTerminals
    private let copyToPasteboard: @MainActor (String) -> Void
    private let defaults: UserDefaults
    private let now: () -> Date
    private let maximumSeconds: TimeInterval
    private var recordingURL: URL?
    private var loaded = false

    /// Recordings shorter than this are clicks by mistake and are thrown away.
    static let minimumSeconds: TimeInterval = 0.4

    /// - Parameters:
    ///   - recorder: The microphone.
    ///   - player: Plays kept recordings back.
    ///   - transcriber: This Mac's Whisper.
    ///   - history: Where every dictation is kept.
    ///   - terminals: Where the text is pasted.
    ///   - copyToPasteboard: Puts text on the general pasteboard.
    ///   - defaults: Where the language and the paste preference live; tests pass a suite.
    ///   - maximumSeconds: Longest recording; ``MobileTranscriptionLimits/macDictation`` allows 15 minutes.
    ///   - now: The clock for the timer and the entries' dates.
    init(
        recorder: any UniConnectDictationRecording,
        player: any UniConnectDictationPlaying,
        transcriber: any UniConnectDictationTranscribing,
        history: UniConnectDictationHistoryStore,
        terminals: any UniConnectDictationTerminals,
        copyToPasteboard: @escaping @MainActor (String) -> Void,
        defaults: UserDefaults,
        maximumSeconds: TimeInterval = MobileTranscriptionLimits.macDictation.maximumSeconds,
        now: @escaping () -> Date = Date.init
    ) {
        self.recorder = recorder
        self.player = player
        self.transcriber = transcriber
        self.history = history
        self.terminals = terminals
        self.copyToPasteboard = copyToPasteboard
        self.defaults = defaults
        self.maximumSeconds = maximumSeconds
        self.now = now
        self.language = defaults.string(forKey: Keys.language).flatMap(UniConnectDictationLanguage.init(rawValue:)) ?? .spanish
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isTranscribing: Bool {
        if case .transcribing = phase { return true }
        return false
    }

    /// The history as the search box filters it, newest first.
    var shownRecords: [UniConnectDictationRecord] {
        UniConnectDictationSearch(query: query).filter(records)
    }

    /// Whether the last dictation already went into a terminal, so the box offers «Pegar otra vez»
    /// instead of inviting a second paste of the same text.
    var lastWasPasted: Bool {
        lastPasteTarget != nil
    }

    /// Bytes of audio the history keeps.
    var keptAudioBytes: Int64 {
        records.reduce(0) { $0 + ($1.audioFile == nil ? 0 : $1.audioBytes) }
    }

    /// Seconds recorded so far and the voice level (0 to 1), for the timer and the meter.
    func meter() -> (seconds: TimeInterval, level: Double) {
        guard case .recording(let startedAt) = phase else { return (0, 0) }
        return (max(0, now().timeIntervalSince(startedAt)), recorder.level())
    }

    /// Reads the history the first time it is needed.
    func loadHistory() async {
        guard !loaded else { return }
        loaded = true
        try? await history.prepareFolder()
        records = await history.records()
    }

    /// The record button: starts, or stops and transcribes.
    func toggleRecording() async {
        switch phase {
        case .idle:
            await startRecording()
        case .recording:
            await stopRecording()
        case .requestingAccess, .transcribing:
            return
        }
    }

    /// Starts recording, asking for the microphone the first time.
    func startRecording() async {
        guard phase == .idle else { return }
        await loadHistory()
        notice = nil
        phase = .requestingAccess
        guard await recorder.requestAccess() else {
            phase = .idle
            notice = .microphoneDenied
            return
        }
        guard phase == .requestingAccess else { return }
        let url = history.newRecordingURL()
        do {
            try await history.prepareFolder()
            try recorder.start(url: url, maximumSeconds: maximumSeconds) { [weak self] in
                guard let self else { return }
                Task { await self.stopRecording(cut: true) }
            }
        } catch {
            phase = .idle
            notice = .failed(Self.couldNotRecordMessage)
            return
        }
        recordingURL = url
        phase = .recording(startedAt: now())
    }

    /// Stops recording, keeps the recording and has Whisper read it. The text is left in the box
    /// as the last dictation; nothing is pasted.
    ///
    /// - Parameter cut: It stopped by itself at the limit.
    func stopRecording(cut: Bool = false) async {
        guard case .recording = phase, let url = recordingURL else { return }
        recordingURL = nil
        let seconds = recorder.stop()
        guard seconds >= Self.minimumSeconds else {
            try? FileManager.default.removeItem(at: url)
            phase = .idle
            notice = .tooShort
            return
        }
        let added: (record: UniConnectDictationRecord, all: [UniConnectDictationRecord])
        do {
            added = try await history.add(recordingAt: url, seconds: seconds, at: now())
        } catch {
            try? FileManager.default.removeItem(at: url)
            phase = .idle
            notice = .failed(Self.couldNotKeepMessage)
            return
        }
        records = added.all
        lastRecordID = added.record.id
        lastPasteTarget = nil
        lastText = ""
        phase = .transcribing(recordID: added.record.id)
        notice = cut ? .cut : nil
        let text = await transcribe(added.record)
        if case .transcribing(added.record.id) = phase {
            phase = .idle
        }
        guard let text, lastRecordID == added.record.id else { return }
        lastText = text
    }

    /// Stops recording and throws it away.
    func cancelRecording() {
        guard isRecording else { return }
        recordingURL = nil
        recorder.cancel()
        phase = .idle
        notice = nil
    }

    /// UniConnect locked: a recording in progress is kept and read, and playback stops.
    func appLocked() async {
        stopPlaying()
        if isRecording {
            await stopRecording()
        }
    }

    /// Reads entry `id` again from its kept audio, without pasting it.
    func retranscribe(_ id: String) async {
        guard !retranscribing.contains(id),
              let record = records.first(where: { $0.id == id }),
              record.audioFile != nil else { return }
        retranscribing.insert(id)
        defer { retranscribing.remove(id) }
        notice = nil
        guard let text = await transcribe(record) else { return }
        if lastRecordID == id {
            lastText = text
        }
    }

    /// Pastes `text` into the terminal focused now.
    func paste(_ text: String) async {
        _ = await pasteNow(text)
    }

    /// Pastes `text` into the terminal focused now and presses Enter there.
    func pasteAndSend(_ text: String) async {
        guard let target = await pasteNow(text) else { return }
        await submit(in: target)
    }

    /// «Enviar» for the last dictation once it is already in a terminal: presses Enter there,
    /// without pasting the text again.
    func sendLast() async {
        guard let lastPasteTarget else { return }
        await submit(in: lastPasteTarget)
    }

    /// Pastes `text` where the keyboard is in UniConnect's front window. When it is the last
    /// dictation, remembers where it went: «Enviar» then presses Enter there, and the history
    /// notes the window.
    private func pasteNow(_ text: String) async -> UniConnectDictationTarget? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let target = terminals.focusedTarget(), terminals.paste(trimmed, into: target) else {
            notice = .noTerminal
            return nil
        }
        notice = .pasted(target.name)
        if let lastRecordID, trimmed == lastText.trimmingCharacters(in: .whitespacesAndNewlines) {
            lastPasteTarget = target
            records = await history.pasted(id: lastRecordID, into: target.name)
        }
        return target
    }

    private func submit(in target: UniConnectDictationTarget) async {
        if await terminals.submit(in: target) {
            notice = .sent(target.name)
        } else {
            notice = .noTerminal
        }
    }

    /// Puts `text` on the pasteboard.
    func copy(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        copyToPasteboard(trimmed)
        notice = .copied
    }

    /// Removes entry `id` with its audio.
    func delete(_ id: String) async {
        if playingID == id { stopPlaying() }
        records = await history.delete(ids: [id])
        if lastRecordID == id {
            lastRecordID = nil
            lastPasteTarget = nil
            lastText = ""
        }
    }

    /// Plays entry `id`, or stops it when it is the one playing.
    func togglePlayback(_ id: String) {
        if playingID == id {
            stopPlaying()
            return
        }
        guard let record = records.first(where: { $0.id == id }),
              let url = history.audioURL(of: record) else { return }
        let started = player.play(url) { [weak self] in
            if self?.playingID == id { self?.playingID = nil }
        }
        playingID = started ? id : nil
    }

    func stopPlaying() {
        player.stop()
        playingID = nil
    }

    /// Forgets the notice once it was seen.
    func dismissNotice() {
        notice = nil
    }

    /// Has Whisper read `record`'s audio and stores the outcome in the history.
    ///
    /// - Returns: The text, or `nil` when there is none (the entry is then marked unread and the
    ///   reason shown).
    private func transcribe(_ record: UniConnectDictationRecord) async -> String? {
        guard let url = history.audioURL(of: record),
              let audio = try? Data(contentsOf: url) else {
            records = await history.unread(id: record.id)
            notice = .failed(Self.couldNotKeepMessage)
            return nil
        }
        do {
            let outcome = try await transcriber.transcribe(
                audio: audio,
                mime: MobileTranscriptionAudioFormat.mp4.rawValue,
                language: language.whisperCode
            )
            let text = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                records = await history.unread(id: record.id)
                notice = .notUnderstood
                return nil
            }
            records = await history.transcribed(id: record.id, text: text, seconds: outcome.seconds)
            return text
        } catch let error as MobileTranscriptionError {
            records = await history.unread(id: record.id)
            notice = .failed(Self.message(for: error))
            return nil
        } catch {
            records = await history.unread(id: record.id)
            notice = .failed(Self.transcriptionFailedMessage)
            return nil
        }
    }

    /// Words a transcription failure for the box.
    static func message(for error: MobileTranscriptionError) -> String {
        switch error {
        case .tooLarge:
            return String(
                localized: "uniconnect.dictation.error.tooLong",
                defaultValue: "La grabación pasa de 15 minutos. El audio queda en el historial."
            )
        case .busy:
            return String(
                localized: "uniconnect.dictation.error.busy",
                defaultValue: "Whisper está ocupado con otro dictado. Vuelve a transcribirlo desde el historial en unos segundos."
            )
        case .unsupported(let message), .ioFailed(let message):
            return message
        case .invalidParams:
            return transcriptionFailedMessage
        }
    }

    private static var transcriptionFailedMessage: String {
        String(
            localized: "uniconnect.dictation.error.failed",
            defaultValue: "No se pudo transcribir. El audio queda en el historial."
        )
    }

    private static var couldNotRecordMessage: String {
        String(
            localized: "uniconnect.dictation.error.couldNotRecord",
            defaultValue: "No se pudo empezar a grabar. Comprueba que el Mac tiene un micrófono disponible."
        )
    }

    private static var couldNotKeepMessage: String {
        String(
            localized: "uniconnect.dictation.error.couldNotKeep",
            defaultValue: "No se pudo guardar la grabación en el historial."
        )
    }
}
