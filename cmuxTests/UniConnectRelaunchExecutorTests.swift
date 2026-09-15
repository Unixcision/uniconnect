import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// La ruta completa: cerrar una IA, traerla de vuelta y decir la verdad sobre lo que pasó.
///
/// Esta suite existe por un caso real del 15-09-2026. El botón cerró una IA viva, la reabrió y
/// después informó de **«0 de 1, se han quedado como estaban»**. Las dos mitades estaban mal: la
/// comprobación miraba el PID del shell del panel, que no cambia nunca, y el aviso afirmaba que no
/// se había tocado nada cuando ya se había cerrado.
@Suite("Ejecutor de relanzado")
struct UniConnectRelaunchExecutorTests {
    /// Un panel de mentira que responde como lo haría tmux y apunta lo que se escribió en él.
    private final class FakePane: UniConnectRelaunchPaneAccess, @unchecked Sendable {
        // Las llamadas del ejecutor son secuenciales; no hay concurrencia real en una prueba.
        private(set) var typed: [String] = []
        /// Toda interacción con el panel, lecturas incluidas: una guarda que lee ya ha tocado algo.
        private(set) var interactions: [String] = []
        private var lookups: [UniConnectRelaunchAgentLookup]
        private var screens: [String]
        private let pane: String?

        init(
            pane: String? = "%1",
            lookups: [UniConnectRelaunchAgentLookup],
            screens: [String]
        ) {
            self.pane = pane
            self.lookups = lookups
            self.screens = screens
        }

        func firstPane(socket: String, session: String) async -> String? {
            interactions.append("firstPane")
            return pane
        }

        func panePID(socket: String, pane: String) async -> Int32? {
            interactions.append("panePID")
            return pane.isEmpty ? nil : 73694
        }

        func agent(
            socket: String,
            pane: String,
            provider: String
        ) async -> UniConnectRelaunchAgentLookup {
            interactions.append("agent")
            return lookups.isEmpty ? .noAgent : lookups.removeFirst()
        }

        func capture(socket: String, pane: String) async -> String? {
            interactions.append("capture")
            return screens.isEmpty ? screens.last : screens.removeFirst()
        }

        func type(socket: String, pane: String, text: String) async {
            interactions.append("type")
            typed.append(text)
        }
    }

    private func proceso(
        _ pid: Int32,
        _ arranque: String,
        argv: [String] = ["claude", "--resume", "091942fc-27af-47e7-ae92-50e7daf1eed3", "--dangerously-skip-permissions"]
    ) -> UniConnectRelaunchAgentLookup {
        .found(.init(pid: pid, startedAt: arranque, argv: argv))
    }

    private func objetivo() -> UniConnectRelaunchExecutor.Target {
        .init(
            key: RelaunchTargetKey(
                destination: .local(machineID: "mac"),
                tmuxServer: "uniconnect-local",
                pane: "uc-creadorplanos",
                generation: 1
            ),
            label: "GESTIONES SISTEMA MAC · CREADOR PLANOS",
            provider: "claude",
            socket: "uniconnect-local",
            session: "uc-creadorplanos",
            previousArgv: [],
            evidence: RelaunchIdentityEvidence(
                processID: 52938,
                pane: "uc-creadorplanos",
                hook: .init(
                    conversationID: "091942fc-27af-47e7-ae92-50e7daf1eed3",
                    processID: 52938,
                    pane: "uc-creadorplanos"
                )
            )
        )
    }

    private func ejecutor(_ panel: FakePane) -> UniConnectRelaunchExecutor {
        UniConnectRelaunchExecutor(driver: panel, settle: {})
    }

    private var salidaConResume: String {
        """
        Resume this session with:
        claude --resume 091942fc-27af-47e7-ae92-50e7daf1eed3
        danielgomezmartin@MacBook-Pro-de-Daniel ~ %
        """
    }

    private var iaLista: String {
        "danielgomezmartin@MacBook-Pro-de-Daniel:~ | Opus 5\n⏵⏵ bypass permissions on (shift+tab to cycle)"
    }

    @Test("Un relanzado que funciona se informa como verificado, no como fallido")
    func aworkingRelaunchIsReportedAsVerified() async {
        let panel = FakePane(
            lookups: [
                proceso(52938, "Mon Sep 15 09:00:00 2026"),  // la IA de antes
                proceso(61111, "Mon Sep 15 11:47:02 2026"),  // la que vuelve
            ],
            screens: [iaLista, salidaConResume, iaLista]
        )

        let resultado = await ejecutor(panel).relaunch(objetivo())

        // Antes esto daba `fallido`, porque se comparaba el PID del shell consigo mismo.
        #expect(resultado.state == .verified)
        #expect(resultado.cause == nil)
        #expect(panel.typed.contains { $0.contains("--resume 091942fc-27af-47e7-ae92-50e7daf1eed3") })
        // Los permisos vuelven como estaban: relanzar no es el momento de cambiarlos.
        #expect(panel.typed.contains { $0.contains("--dangerously-skip-permissions") })
    }

    @Test("Un PID reciclado no cuela como proceso nuevo")
    func arecycledIdentifierDoesNotPassAsANewProcess() async {
        let panel = FakePane(
            lookups: [
                proceso(52938, "Mon Sep 15 09:00:00 2026"),
                proceso(52938, "Mon Sep 15 09:00:00 2026"),  // el mismo de verdad
            ],
            screens: [iaLista, salidaConResume, iaLista]
        )

        let resultado = await ejecutor(panel).relaunch(objetivo())

        #expect(resultado.state != .verified)
    }

    @Test("Un panel en su shell se deja en paz, sin escribir nada")
    func apaneAtItsShellIsLeftAlone() async {
        let panel = FakePane(lookups: [.noAgent], screens: ["danielgomezmartin@Mac ~ %"])

        let resultado = await ejecutor(panel).relaunch(objetivo())

        #expect(resultado.state == .skipped)
        // Lo importante no es el estado: es que no se escribió una sola tecla en el panel.
        #expect(panel.typed.isEmpty)
    }

    @Test("Con dos IA del mismo proveedor no se cierra nada")
    func twoAgentsMeanNothingIsClosed() async {
        let panel = FakePane(lookups: [.ambiguous], screens: [iaLista])

        let resultado = await ejecutor(panel).relaunch(objetivo())

        #expect(resultado.state == .skipped)
        #expect(resultado.cause == .ambiguousIdentity)
        #expect(panel.typed.isEmpty)
    }

    @Test("Si no se puede leer el proceso, no se toca la ventana")
    func anunreadableProcessLeavesTheWindowAlone() async {
        let panel = FakePane(lookups: [.unreadable], screens: [iaLista])

        let resultado = await ejecutor(panel).relaunch(objetivo())

        #expect(resultado.state == .failed)
        #expect(resultado.cause == .hostUnreachable)
        #expect(panel.typed.isEmpty)
    }

    @Test("Una ventana de caja SSH no se toca ni para leerla")
    func aremoteWindowIsNotEvenRead() async {
        let panel = FakePane(
            lookups: [proceso(52938, "Mon Sep 15 09:00:00 2026")],
            screens: [iaLista, salidaConResume, iaLista]
        )
        let remoto = UniConnectRelaunchExecutor.Target(
            key: RelaunchTargetKey(
                destination: .ssh(user: "root", host: "185.237.234.231", port: 22),
                tmuxServer: "uniconnect",
                pane: "valenciarusa",
                generation: 1
            ),
            label: "VALENCIARUSA · valenciarusa",
            provider: "claude",
            socket: "uniconnect",
            session: "valenciarusa",
            previousArgv: []
        )

        let resultado = await UniConnectRelaunchExecutor(driver: panel, settle: {}).relaunch(remoto)

        #expect(resultado.state == .skipped)
        #expect(resultado.cause == .unsupported)
        // Cero llamadas al driver, lecturas incluidas: una guarda que primero mira ya empezó.
        #expect(panel.interactions.isEmpty)
        #expect(panel.typed.isEmpty)
    }

    @Test("Una ventana local sí se relanza, que es justo lo que se pedía")
    func alocalWindowIsRelaunched() async {
        let panel = FakePane(
            lookups: [
                proceso(52938, "Mon Sep 15 09:00:00 2026"),
                proceso(61111, "Mon Sep 15 11:47:02 2026"),
            ],
            screens: [iaLista, salidaConResume, iaLista]
        )

        // Política del producto, sin nada inyectado.
        let resultado = await UniConnectRelaunchExecutor(driver: panel, settle: {}).relaunch(objetivo())

        #expect(resultado.state == .verified)
    }

    @Test("Las opciones se leen del proceso vivo, no del registro")
    func theflagsComeFromTheLiveProcess() async {
        // El registro no las guarda: el objetivo llega con `previousArgv: []`. Si el relanzado
        // se apoyara en él, la IA volvería sin sus permisos y nadie se enteraría hasta usarla.
        let panel = FakePane(
            lookups: [
                proceso(52938, "Mon Sep 15 09:00:00 2026",
                        argv: ["claude", "--resume", "091942fc-27af-47e7-ae92-50e7daf1eed3",
                               "--dangerously-skip-permissions"]),
                proceso(61111, "Mon Sep 15 11:47:02 2026"),
            ],
            screens: [iaLista, salidaConResume, iaLista]
        )

        _ = await UniConnectRelaunchExecutor(driver: panel, settle: {}).relaunch(objetivo())

        #expect(panel.typed.contains { $0.contains("--dangerously-skip-permissions") })
    }

    @Test("Una IA sin ese permiso no lo gana al relanzarse")
    func anagentWithoutThatPermissionDoesNotGainIt() async {
        // Relanzar tampoco es el momento de dar permisos que no había.
        let panel = FakePane(
            lookups: [
                proceso(52938, "Mon Sep 15 09:00:00 2026",
                        argv: ["claude", "--resume", "091942fc-27af-47e7-ae92-50e7daf1eed3"]),
                proceso(61111, "Mon Sep 15 11:47:02 2026"),
            ],
            screens: [iaLista, salidaConResume, iaLista]
        )

        _ = await UniConnectRelaunchExecutor(driver: panel, settle: {}).relaunch(objetivo())

        #expect(panel.typed.allSatisfy { !$0.contains("--dangerously-skip-permissions") })
    }

    @Test("Lo que queda bloqueado sigue nombrado, para que vaciarlo sea deliberado")
    func whatIsStillRefusedStaysNamed() {
        #expect(!UniConnectRelaunchClosurePolicy.outstandingConditions.isEmpty)
        #expect(UniConnectRelaunchClosurePolicy.outstandingConditions.contains { $0.contains("SSH") })
    }

    @Test("Una pregunta de confianza de carpeta la contesta una persona")
    func afolderTrustQuestionIsLeftForAPerson() async {
        let panel = FakePane(
            lookups: [proceso(52938, "Mon Sep 15 09:00:00 2026")],
            screens: [iaLista, salidaConResume, "Do you trust the files in this folder?\nYes, I trust this folder"]
        )

        let resultado = await ejecutor(panel).relaunch(objetivo())

        #expect(resultado.state == .needsUser)
        #expect(resultado.cause == .folderTrust)
    }
}
