import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

// MARK: - Dobles

/// Micrófono falso: escribe unos bytes donde se le pide y devuelve la duración preparada.
@MainActor
private final class FakeRecorder: UniConnectDictationRecording {
    var access = true
    var seconds: TimeInterval = 4
    private(set) var startedURL: URL?
    private(set) var cancelled = false
    private(set) var onLimit: (@MainActor () -> Void)?

    func requestAccess() async -> Bool { access }

    func start(url: URL, maximumSeconds: TimeInterval, onLimit: @escaping @MainActor () -> Void) throws {
        try Data("audio de prueba".utf8).write(to: url)
        startedURL = url
        self.onLimit = onLimit
    }

    func stop() -> TimeInterval {
        startedURL = nil
        return seconds
    }

    func cancel() {
        if let startedURL { try? FileManager.default.removeItem(at: startedURL) }
        startedURL = nil
        cancelled = true
    }

    func level() -> Double { 0.5 }
}

@MainActor
private final class FakePlayer: UniConnectDictationPlaying {
    private(set) var played: [URL] = []
    func play(_ url: URL, onFinish: @escaping @MainActor () -> Void) -> Bool {
        played.append(url)
        return true
    }
    func stop() {}
}

/// Whisper falso: devuelve los textos en orden, o el error preparado, y apunta el idioma pedido.
private actor FakeTranscriber: UniConnectDictationTranscribing {
    private var texts: [String]
    private let error: MobileTranscriptionError?
    private(set) var languages: [String?] = []
    private(set) var audios: [Data] = []

    init(texts: [String] = [], error: MobileTranscriptionError? = nil) {
        self.texts = texts
        self.error = error
    }

    func transcribe(audio: Data, mime: String, language: String?) async throws -> MobileTranscriptionOutcome {
        languages.append(language)
        audios.append(audio)
        if let error { throw error }
        let text = texts.isEmpty ? "" : texts.removeFirst()
        return MobileTranscriptionOutcome(text: text, engine: "whisper.cpp/falso", seconds: 3.5, tookMs: 10)
    }
}

@MainActor
private final class FakeTerminals: UniConnectDictationTerminals {
    var focused: UniConnectDictationTarget?
    var accepts = true
    private(set) var pastes: [(String, UniConnectDictationTarget)] = []
    private(set) var submits: [UniConnectDictationTarget] = []
    /// Paste and Enter in the order they reached the terminals.
    private(set) var order: [String] = []

    func focusedTarget() -> UniConnectDictationTarget? { focused }

    func paste(_ text: String, into target: UniConnectDictationTarget) -> Bool {
        guard accepts else { return false }
        pastes.append((text, target))
        order.append("pegar")
        return true
    }

    func submit(in target: UniConnectDictationTarget) async -> Bool {
        guard accepts else { return false }
        submits.append(target)
        order.append("enter")
        return true
    }
}

/// Carpetas temporales y entradas de historial para las pruebas.
private enum DictationFixture {
    static func folder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("uc-dictado-\(UUID().uuidString)", isDirectory: true)
    }

    static func record(
        _ id: String,
        text: String? = "hola",
        audio: String? = nil,
        bytes: Int64 = 0,
        pastedInto: String? = nil
    ) -> UniConnectDictationRecord {
        UniConnectDictationRecord(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_794_500_000),
            text: text,
            state: text == nil ? .unread : .done,
            audioFile: audio,
            audioBytes: bytes,
            seconds: 3,
            pastedInto: pastedInto
        )
    }
}

// MARK: - Botón flotante

@Suite("Dictado: dónde se pone el botón flotante")
struct UniConnectDictationBubbleLayoutTests {
    private let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)

    @Test("de entrada está abajo a la derecha, dentro del área visible")
    func startsBottomRight() {
        let frame = UniConnectDictationBubbleLayout().bubbleFrame(in: screen)
        #expect(frame.maxX == screen.maxX - UniConnectDictationBubbleLayout.margin)
        #expect(frame.minY == screen.minY + 96)
        #expect(frame.width == UniConnectDictationBubbleLayout.bubbleDiameter)
    }

    @Test("la ventana del botón le deja margen alrededor para crecer sin cortarse")
    func bubbleWindowHasRoomAround() {
        let layout = UniConnectDictationBubbleLayout()
        let button = layout.bubbleFrame(in: screen)
        let window = layout.frame(in: screen)
        let grown = button.insetBy(dx: -button.width * 0.04, dy: -button.height * 0.04)
        #expect(window.contains(grown))
        #expect(UniConnectDictationBubbleLayout.bubble(inWindow: window) == button)
    }

    @Test("soltado en la mitad izquierda se pega al borde izquierdo, a esa altura")
    func snapsToTheNearerEdge() {
        let dropped = CGRect(x: 300, y: 400, width: 52, height: 52)
        let layout = UniConnectDictationBubbleLayout.settled(droppedAt: dropped, in: screen)
        #expect(layout.edge == .left)
        #expect(!layout.docked)
        #expect(layout.bubbleFrame(in: screen).minX == screen.minX + UniConnectDictationBubbleLayout.margin)
        #expect(layout.bubbleFrame(in: screen).minY == 400)
    }

    @Test("soltado medio fuera del borde se esconde como pastillita pegada a ese borde")
    func dropsPastTheEdgeIntoAPill() {
        let dropped = CGRect(x: screen.maxX - 30, y: 300, width: 52, height: 52)
        let layout = UniConnectDictationBubbleLayout.settled(droppedAt: dropped, in: screen)
        #expect(layout.edge == .right)
        #expect(layout.docked)
        let pill = layout.frame(in: screen)
        #expect(pill.maxX == screen.maxX)
        #expect(pill.size == UniConnectDictationBubbleLayout.pillWindowSize)
        #expect(abs(pill.midY - (300 + 26)) < 0.5)
    }

    @Test("pegado al borde pero sin pasarse no se esconde")
    func touchingTheEdgeIsNotDocking() {
        let dropped = CGRect(x: screen.maxX - 52, y: 300, width: 52, height: 52)
        #expect(!UniConnectDictationBubbleLayout.settled(droppedAt: dropped, in: screen).docked)
    }

    @Test("la pastillita se desliza por su borde y no se sale de la pantalla")
    func pillSlidesAlongItsEdge() {
        let dragged = CGRect(x: screen.maxX - 18, y: -500, width: 18, height: 72)
        let layout = UniConnectDictationBubbleLayout.slid(pillAt: dragged, edge: .right, in: screen)
        #expect(layout.docked)
        #expect(layout.edge == .right)
        #expect(layout.frame(in: screen).minY >= screen.minY + UniConnectDictationBubbleLayout.margin)
    }

    @Test("una altura guardada de otra pantalla más alta se recoloca dentro de esta")
    func storedOffsetIsClamped() {
        var layout = UniConnectDictationBubbleLayout()
        layout.bottomOffset = 5_000
        let frame = layout.bubbleFrame(in: screen)
        #expect(frame.maxY <= screen.maxY - UniConnectDictationBubbleLayout.margin)
    }

    @Test("la caja se abre al lado del botón, hacia dentro, y cabe en la pantalla", arguments: [
        UniConnectDictationBubbleLayout.Edge.right, .left,
    ])
    func boxOpensInward(edge: UniConnectDictationBubbleLayout.Edge) {
        let layout = UniConnectDictationBubbleLayout(edge: edge, bottomOffset: 96, docked: false)
        let bubble = layout.bubbleFrame(in: screen)
        let box = layout.boxFrame(in: screen)
        #expect(screen.contains(box))
        #expect(!box.intersects(bubble))
        #expect(box.minY == bubble.minY)
        if edge == .right {
            #expect(box.maxX <= bubble.minX)
        } else {
            #expect(box.minX >= bubble.maxX)
        }
    }

    @Test("en una pantalla pequeña la caja se encoge en vez de salirse")
    func boxShrinksOnASmallScreen() {
        let small = CGRect(x: 0, y: 0, width: 400, height: 500)
        let box = UniConnectDictationBubbleLayout().boxFrame(in: small)
        #expect(small.contains(box))
        #expect(box.height <= 500 - 2 * UniConnectDictationBubbleLayout.margin)
    }
}

// MARK: - Historial

@Suite("Dictado: retención y búsqueda del historial")
struct UniConnectDictationRetentionTests {
    @Test("los recientes conservan el audio; los viejos lo pierden y su texto se queda")
    func audioGoesFirstOldestFirst() {
        let retention = UniConnectDictationRetention(maxRecords: 10, maxAudioBytes: 250)
        let records = [
            DictationFixture.record("nuevo", audio: "a.m4a", bytes: 100),
            DictationFixture.record("medio", audio: "b.m4a", bytes: 100),
            DictationFixture.record("viejo", audio: "c.m4a", bytes: 100),
            DictationFixture.record("sin-audio"),
        ]
        let trim = retention.trim(records)
        #expect(trim.dropRecords.isEmpty)
        #expect(trim.dropAudio == ["viejo"])
    }

    @Test("pasado el máximo de dictados se van enteros los más viejos")
    func recordLimit() {
        let retention = UniConnectDictationRetention(maxRecords: 2, maxAudioBytes: 1_000)
        let trim = retention.trim([DictationFixture.record("1"), DictationFixture.record("2"), DictationFixture.record("3"), DictationFixture.record("4")])
        #expect(trim.dropRecords == ["3", "4"])
    }

    @Test("los límites por defecto son los del móvil")
    func phoneLimits() {
        let retention = UniConnectDictationRetention()
        #expect(retention.maxRecords == 200)
        #expect(retention.maxAudioBytes == 300 * 1_048_576)
    }

    @Test("la búsqueda no distingue mayúsculas ni tildes, acepta trozos y mira la ventana")
    func searchIsLoose() {
        let records = [
            DictationFixture.record("a", text: "Relanza la máquina de PREPRO", pastedInto: "IBERIAVO · prepro"),
            DictationFixture.record("b", text: "Revisa el despliegue del MINIPC"),
            DictationFixture.record("c", text: nil),
        ]
        #expect(UniConnectDictationSearch(query: "maquina relan").filter(records).map(\.id) == ["a"])
        #expect(UniConnectDictationSearch(query: "IBERIAVO").filter(records).map(\.id) == ["a"])
        #expect(UniConnectDictationSearch(query: "despliegue minipc").filter(records).map(\.id) == ["b"])
        #expect(UniConnectDictationSearch(query: "  ").filter(records).count == 3)
        #expect(UniConnectDictationSearch(query: "vps").filter(records).isEmpty)
    }
}

@Suite("Dictado: historial en disco")
struct UniConnectDictationHistoryStoreTests {
    private func recording(in store: UniConnectDictationHistoryStore, bytes: Int = 64) throws -> URL {
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        let url = store.newRecordingURL()
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    @Test("la grabación entra en el historial con su audio antes de transcribirse, y sobrevive a reabrir")
    func keepsThenTranscribesThenPersists() async throws {
        let folder = DictationFixture.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = UniConnectDictationHistoryStore(directory: folder)
        let source = try recording(in: store)
        let added = try await store.add(recordingAt: source, seconds: 2, at: Date(timeIntervalSince1970: 1_794_500_000))
        #expect(added.record.state == .transcribing)
        #expect(added.record.audioBytes == 64)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let audio = try #require(store.audioURL(of: added.record))
        #expect(FileManager.default.fileExists(atPath: audio.path))

        _ = await store.transcribed(id: added.record.id, text: "Hola, Mac", seconds: 2.4)
        _ = await store.pasted(id: added.record.id, into: "GYM DATOS")

        let reopened = await UniConnectDictationHistoryStore(directory: folder).records()
        #expect(reopened.count == 1)
        #expect(reopened[0].text == "Hola, Mac")
        #expect(reopened[0].state == .done)
        #expect(reopened[0].seconds == 2.4)
        #expect(reopened[0].pastedInto == "GYM DATOS")
        #expect(reopened[0].createdAt == Date(timeIntervalSince1970: 1_794_500_000))
    }

    @Test("lo que se estaba transcribiendo al cerrar vuelve como sin leer, con su audio")
    func interruptedComesBackUnread() async throws {
        let folder = DictationFixture.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = UniConnectDictationHistoryStore(directory: folder)
        _ = try await store.add(recordingAt: try recording(in: store), seconds: 2, at: Date())
        let reopened = await UniConnectDictationHistoryStore(directory: folder).records()
        #expect(reopened.first?.state == .unread)
        #expect(reopened.first?.audioFile != nil)
    }

    @Test("una grabación a medias de un cierre brusco se borra; nada más")
    func unfinishedRecordingIsRemoved() async throws {
        let folder = DictationFixture.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = UniConnectDictationHistoryStore(directory: folder)
        let kept = try await store.add(recordingAt: try recording(in: store), seconds: 2, at: Date()).record
        let leftover = try recording(in: store)
        let reopened = UniConnectDictationHistoryStore(directory: folder)
        let records = await reopened.records()
        #expect(records.map(\.id) == [kept.id])
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: try #require(reopened.audioURL(of: records[0])).path))
    }

    @Test("la carpeta y el índice son privados")
    func privateFiles() async throws {
        let folder = DictationFixture.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = UniConnectDictationHistoryStore(directory: folder)
        let added = try await store.add(recordingAt: try recording(in: store), seconds: 2, at: Date())
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        let indexMode = try FileManager.default.attributesOfItem(
            atPath: folder.appendingPathComponent("indice.json").path
        )[.posixPermissions] as? Int
        let audioMode = try FileManager.default.attributesOfItem(
            atPath: try #require(store.audioURL(of: added.record)).path
        )[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
        #expect(indexMode == 0o600)
        #expect(audioMode == 0o600)
    }

    @Test("borrar quita la entrada y su audio; la retención quita el audio del disco")
    func deleteAndRetentionTouchTheDisk() async throws {
        let folder = DictationFixture.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = UniConnectDictationHistoryStore(
            directory: folder,
            retention: UniConnectDictationRetention(maxRecords: 10, maxAudioBytes: 150)
        )
        let first = try await store.add(recordingAt: try recording(in: store, bytes: 100), seconds: 1, at: Date()).record
        let second = try await store.add(recordingAt: try recording(in: store, bytes: 100), seconds: 1, at: Date()).record
        let afterTrim = await store.records()
        #expect(afterTrim.first { $0.id == first.id }?.audioFile == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(first.id).m4a").path))

        let secondAudio = try #require(store.audioURL(of: second))
        let remaining = await store.delete(ids: [second.id])
        #expect(remaining.map(\.id) == [first.id])
        #expect(!FileManager.default.fileExists(atPath: secondAudio.path))
    }
}

// MARK: - De principio a fin

@MainActor
@Suite("Dictado: grabar, transcribir y pegar")
struct UniConnectDictationModelTests {
    private let gym = UniConnectDictationTarget(workspaceID: UUID(), panelID: UUID(), name: "GESTIONES · GYM DATOS")

    private struct Rig {
        let model: UniConnectDictationModel
        let recorder: FakeRecorder
        let player: FakePlayer
        let transcriber: FakeTranscriber
        let terminals: FakeTerminals
        let folder: URL
        let copied: CopiedTexts
    }

    @MainActor
    private final class CopiedTexts {
        var texts: [String] = []
    }

    private func makeRig(texts: [String] = ["Revisa los logs del MINIPC"], error: MobileTranscriptionError? = nil) -> Rig {
        let folder = DictationFixture.folder()
        let recorder = FakeRecorder()
        let player = FakePlayer()
        let transcriber = FakeTranscriber(texts: texts, error: error)
        let terminals = FakeTerminals()
        terminals.focused = gym
        let copied = CopiedTexts()
        let defaults = UserDefaults(suiteName: "uc-dictado-\(UUID().uuidString)")!
        let model = UniConnectDictationModel(
            recorder: recorder,
            player: player,
            transcriber: transcriber,
            history: UniConnectDictationHistoryStore(directory: folder),
            terminals: terminals,
            copyToPasteboard: { copied.texts.append($0) },
            defaults: defaults
        )
        return Rig(
            model: model,
            recorder: recorder,
            player: player,
            transcriber: transcriber,
            terminals: terminals,
            folder: folder,
            copied: copied
        )
    }

    @Test("parar transcribe y deja el texto en la caja: no se pega nada hasta pulsar «Pegar»")
    func stopNeverPastes() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        await rig.model.toggleRecording()
        #expect(rig.model.isRecording)
        await rig.model.toggleRecording()

        #expect(rig.model.phase == .idle)
        #expect(rig.terminals.order.isEmpty)
        #expect(rig.model.notice == nil)
        #expect(rig.model.lastText == "Revisa los logs del MINIPC")
        #expect(!rig.model.lastWasPasted)
        let entry = try #require(rig.model.records.first)
        #expect(entry.state == .done)
        #expect(entry.pastedInto == nil)
        #expect(entry.seconds == 3.5)
        #expect(entry.audioFile != nil)
        #expect(await rig.transcriber.languages == ["es"])
        #expect(await rig.transcriber.audios.first == Data("audio de prueba".utf8))
    }

    @Test("«Pegar» va a la terminal enfocada al pulsarlo, una vez, y el historial apunta dónde")
    func pasteGoesWhereTheKeyboardIs() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        await rig.model.startRecording()
        await rig.model.stopRecording()
        let other = UniConnectDictationTarget(workspaceID: UUID(), panelID: UUID(), name: "OTRA")
        rig.terminals.focused = other
        await rig.model.paste(rig.model.lastText)
        #expect(rig.terminals.pastes.map { $0.1 } == [other])
        #expect(rig.terminals.order == ["pegar"])
        #expect(rig.model.notice == .pasted("OTRA"))
        #expect(rig.model.lastWasPasted)
        #expect(rig.model.records.first?.pastedInto == "OTRA")
    }

    @Test("sin permiso de micrófono no se graba nada y la caja lo dice")
    func microphoneDenied() async {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        rig.recorder.access = false
        await rig.model.toggleRecording()
        #expect(rig.model.phase == .idle)
        #expect(rig.model.notice == .microphoneDenied)
        #expect(rig.model.records.isEmpty)
    }

    @Test("si Whisper falla el audio se queda en el historial sin leer")
    func failureKeepsTheAudio() async throws {
        let rig = makeRig(error: .ioFailed("No se pudo transcribir el audio en el equipo."))
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        await rig.model.startRecording()
        await rig.model.stopRecording()
        let entry = try #require(rig.model.records.first)
        #expect(entry.state == .unread)
        #expect(entry.audioFile != nil)
        #expect(rig.model.lastText.isEmpty)
        #expect(rig.terminals.order.isEmpty)
        #expect(rig.model.notice == .failed("No se pudo transcribir el audio en el equipo."))
    }

    @Test("un clic sin querer, demasiado corto, no deja nada")
    func tooShortIsDiscarded() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        rig.recorder.seconds = 0.2
        await rig.model.startRecording()
        await rig.model.stopRecording()
        #expect(rig.model.records.isEmpty)
        #expect(rig.model.notice == .tooShort)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: rig.folder.path)) ?? []
        #expect(leftovers.allSatisfy { !$0.hasSuffix(".m4a") })
    }

    @Test("después de «Pegar», «Enviar» solo pulsa Enter allí: el texto no se pega dos veces")
    func sendAfterPasteDoesNotPasteAgain() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        await rig.model.startRecording()
        await rig.model.stopRecording()
        await rig.model.paste(rig.model.lastText)
        rig.terminals.focused = UniConnectDictationTarget(workspaceID: UUID(), panelID: UUID(), name: "OTRA")
        await rig.model.sendLast()
        #expect(rig.terminals.pastes.count == 1)
        #expect(rig.terminals.submits == [gym])
        #expect(rig.terminals.order == ["pegar", "enter"])
        #expect(rig.model.notice == .sent(gym.name))
    }

    @Test("«Pegar y enviar» pega una vez en la terminal enfocada y después pulsa Enter")
    func pasteAndSend() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        await rig.model.startRecording()
        await rig.model.stopRecording()
        #expect(!rig.model.lastWasPasted)
        await rig.model.pasteAndSend(rig.model.lastText)
        #expect(rig.terminals.pastes.map { $0.0 } == ["Revisa los logs del MINIPC"])
        #expect(rig.terminals.order == ["pegar", "enter"])
        #expect(rig.model.notice == .sent(gym.name))
        #expect(rig.model.lastWasPasted)
    }

    @Test("sin terminal enfocada no se pega ni se pulsa Enter en ningún sitio, y se avisa")
    func noFocusedTerminal() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        await rig.model.startRecording()
        await rig.model.stopRecording()
        rig.terminals.focused = nil
        await rig.model.paste(rig.model.lastText)
        #expect(rig.model.notice == .noTerminal)
        await rig.model.pasteAndSend(rig.model.lastText)
        #expect(rig.terminals.order.isEmpty)
        #expect(rig.model.notice == .noTerminal)
        #expect(rig.model.lastText == "Revisa los logs del MINIPC")
        #expect(!rig.model.lastWasPasted)
    }

    @Test("volver a transcribir cambia el texto y no pega en ningún sitio")
    func retranscribeDoesNotPaste() async throws {
        let rig = makeRig(texts: ["Primera versión", "Segunda versión"])
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        await rig.model.startRecording()
        await rig.model.stopRecording()
        let id = try #require(rig.model.records.first?.id)
        await rig.model.retranscribe(id)
        #expect(rig.model.records.first?.text == "Segunda versión")
        #expect(rig.model.lastText == "Segunda versión")
        #expect(rig.terminals.order.isEmpty)
    }

    @Test("bloquear UniConnect a mitad de grabación la guarda y la transcribe")
    func lockKeepsTheRecording() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        await rig.model.startRecording()
        await rig.model.appLocked()
        #expect(!rig.model.isRecording)
        #expect(rig.model.records.first?.text == "Revisa los logs del MINIPC")
        #expect(rig.terminals.order.isEmpty)
    }

    @Test("al llegar al tope la grabación sigue como si se hubiera parado a mano, y se avisa")
    func limitStopsLikeTheUser() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        await rig.model.startRecording()
        await rig.model.stopRecording(cut: true)
        #expect(rig.model.records.first?.state == .done)
        #expect(rig.model.notice == .cut)
        #expect(rig.terminals.order.isEmpty)
    }

    @Test("descartar tira la grabación sin tocar el historial")
    func cancelThrowsAway() async {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        await rig.model.startRecording()
        rig.model.cancelRecording()
        #expect(rig.recorder.cancelled)
        #expect(rig.model.phase == .idle)
        #expect(rig.model.records.isEmpty)
    }

    @Test("el idioma elegido llega a Whisper")
    func languageReachesWhisper() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        rig.model.language = .automatic
        await rig.model.startRecording()
        await rig.model.stopRecording()
        #expect(await rig.transcriber.languages == [nil])
    }

    @Test("copiar, pegar a mano, escuchar y borrar desde el historial")
    func historyActions() async throws {
        let rig = makeRig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        await rig.model.startRecording()
        await rig.model.stopRecording()
        let entry = try #require(rig.model.records.first)

        rig.model.copy("  Revisa los logs  ")
        #expect(rig.copied.texts == ["Revisa los logs"])
        #expect(rig.model.notice == .copied)

        await rig.model.paste(try #require(entry.text))
        #expect(rig.terminals.pastes.count == 1)

        rig.model.togglePlayback(entry.id)
        #expect(rig.model.playingID == entry.id)
        #expect(rig.player.played.count == 1)
        rig.model.togglePlayback(entry.id)
        #expect(rig.model.playingID == nil)

        await rig.model.delete(entry.id)
        #expect(rig.model.records.isEmpty)
        #expect(rig.model.lastText.isEmpty)
        #expect(!rig.model.lastWasPasted)
    }
}
