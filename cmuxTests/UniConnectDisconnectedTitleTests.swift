import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// La marca «· desconectado» vive dentro del título guardado: una ventana SSH que se restaura
/// enganchada no puede seguir diciendo «desconectado» en la lista del Mac ni en la del móvil.
@Suite("UniConnect: marca de ventana SSH desconectada")
struct UniConnectDisconnectedTitleTests {
    let mark = UniConnectDisconnectedTitle(suffix: "· desconectado")

    @Test("Al restaurar enganchada, la ventana pierde la marca que guardó la sesión anterior")
    func restoreThatAttachesDropsTheSavedMark() {
        #expect(mark.restoredTitle("claudefixerrors· desconectado", attaches: true) == "claudefixerrors")
        #expect(mark.restoredTitle("miamigoclaude", attaches: true) == "miamigoclaude")
        #expect(mark.restoredTitle(nil, attaches: true) == nil)
    }

    @Test("Si la restauración no puede enganchar, el título guardado no se toca")
    func restoreThatCannotAttachKeepsTheTitle() {
        #expect(mark.restoredTitle("claudefixerrors· desconectado", attaches: false) == "claudefixerrors· desconectado")
    }

    @Test("Una marca sin nada delante no deja la ventana con un título vacío")
    func onlyTheMarkLeavesNoTitle() {
        #expect(mark.restoredTitle("· desconectado", attaches: true) == nil)
    }

    @Test("Se reconocen las grafías de versiones anteriores y las marcas repetidas", arguments: [
        "codexemergencia · desconectado",
        "codexemergencia· desconectado· desconectado",
        "codexemergencia · desconectada",
        "codexemergencia · disconnected",
    ])
    func knownSpellingsAreStripped(saved: String) {
        #expect(mark.stripped(saved) == "codexemergencia")
    }

    @Test("Marcar pone una sola marca aunque ya la tuviera, y quitarla devuelve el nombre")
    func markingIsIdempotent() {
        let once = mark.marked("claudesupport")
        #expect(once == "claudesupport· desconectado")
        #expect(mark.marked(once) == once)
        #expect(mark.stripped(once) == "claudesupport")
    }

    @Test("Un nombre que solo se parece a la marca no se recorta")
    func lookalikeNamesSurvive() {
        #expect(mark.stripped("proxy-desconectado") == "proxy-desconectado")
        #expect(mark.stripped("desconectado") == "desconectado")
    }
}
