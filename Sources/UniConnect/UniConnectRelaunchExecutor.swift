import CMUXAgentLaunch
import CmuxProcess
import Foundation

/// Closes one agent and brings the same conversation back, in its own pane.
///
/// The whole point is that it never types into a pane it has not just read. Doing this by hand to 26
/// windows, three of them were not at a prompt: one sat on a question about work in flight, one had
/// a task list where the keys went into a search box, and one came back asking whether the folder
/// was trusted with "No, exit" already selected. A blind Enter would have killed the session that
/// had just been opened.
struct UniConnectRelaunchExecutor: Sendable {
    /// One window to act on.
    struct Target: Sendable {
        let key: RelaunchTargetKey
        let label: String
        let provider: String
        let socket: String
        let session: String
        /// The argv the pane was started with, so its flags come back unchanged.
        let previousArgv: [String]
        /// Evidence gathered off the screen about which conversation lives here.
        let evidence: RelaunchIdentityEvidence?

        init(
            key: RelaunchTargetKey,
            label: String,
            provider: String,
            socket: String,
            session: String,
            previousArgv: [String],
            evidence: RelaunchIdentityEvidence? = nil
        ) {
            self.key = key
            self.label = label
            self.provider = provider
            self.socket = socket
            self.session = session
            self.previousArgv = previousArgv
            self.evidence = evidence
        }
    }

    private let driver: any UniConnectRelaunchPaneAccess
    private let dialects: RelaunchDialects
    private let closurePolicy: UniConnectRelaunchClosurePolicy
    private let sequencer = RelaunchPaneSequencer()
    /// Injected so tests do not wait for a terminal to repaint.
    private let settle: @Sendable () async -> Void

    init(
        driver: any UniConnectRelaunchPaneAccess = UniConnectRelaunchTmuxDriver(),
        dialects: RelaunchDialects = .known,
        closurePolicy: UniConnectRelaunchClosurePolicy = .current,
        settle: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) }
    ) {
        self.driver = driver
        self.dialects = dialects
        self.closurePolicy = closurePolicy
        self.settle = settle
    }

    /// Relaunches `target`, reporting where it got to.
    func relaunch(_ target: Target) async -> RelaunchOperation.Result {
        // Antes de leer nada, y mucho antes de cerrar nada. Ver ``UniConnectRelaunchClosurePolicy``:
        // una ventana local sí se relanza; una de caja SSH no, porque no hay conversación que
        // devolverle después.
        if let refusal = closurePolicy.refusal(for: target.key) {
            return .init(key: target.key, state: .skipped, cause: refusal)
        }
        // An agent this build does not know how to close and verify is left exactly as it is.
        guard let dialect = dialects.dialect(for: target.provider) else {
            return .init(key: target.key, state: .skipped, cause: .unsupported)
        }
        guard let pane = await driver.firstPane(socket: target.socket, session: target.session),
              await driver.panePID(socket: target.socket, pane: pane) != nil else {
            return .init(key: target.key, state: .failed, cause: .hostUnreachable)
        }
        // The agent's own process, not the pane's shell: the shell survives the relaunch unchanged,
        // so it can neither prove a new process nor catch a close that silently failed. Every answer
        // other than one unmistakable agent leaves the window alone — a window nobody touched is
        // always recoverable, and one closed on a guess is not.
        let before: UniConnectRelaunchAgentProcess
        switch await driver.agent(socket: target.socket, pane: pane, provider: target.provider) {
        case let .found(process):
            before = process
        case .noAgent:
            return .init(key: target.key, state: .skipped, cause: .ambiguousIdentity)
        case .ambiguous:
            return .init(key: target.key, state: .skipped, cause: .ambiguousIdentity)
        case .unreadable:
            return .init(key: target.key, state: .failed, cause: .hostUnreachable)
        }

        // Identity first: nothing is closed before it is known what would have to come back.
        var conversation = target.evidence.flatMap { dialect.conversation(from: $0) }

        // Y fidelidad primero también: si estas opciones no se pueden devolver tal y como estaban,
        // esta ventana no se cierra. Comprobarlo **después** de cerrar —que es donde estaba— dejaba
        // la IA muerta y luego anunciaba que no se podía reabrir, exactamente el orden que este
        // trabajo existe para arreglar. Lo que se añade al reabrir es un identificador de
        // conversación, que no trae sintaxis; si lo de antes es seguro, lo de después también.
        guard UniConnectRelaunchCommandLine.line(from: before.argv) != nil || before.argv.isEmpty else {
            return .init(key: target.key, state: .skipped, cause: .ambiguousIdentity)
        }

        switch await close(target: target, pane: pane, dialect: dialect) {
        case let .failure(cause):
            return .init(key: target.key, state: cause == .folderTrust ? .needsUser : .failed, cause: cause)
        case let .success(printed):
            // What an agent prints on its way out beats anything guessed beforehand.
            conversation = printed ?? conversation
        }

        // Las opciones que tenía puestas, leídas del proceso vivo antes de cerrarlo y no del
        // registro, que no las guarda. Relanzar no es el momento de cambiar lo que una IA puede
        // hacer, ni para darle más ni para quitarle.
        let previousArgv = before.argv.isEmpty ? target.previousArgv : before.argv
        guard let conversation,
              let argv = dialect.invocation(conversation: conversation, previousArgv: previousArgv) else {
            // Closed but unidentifiable: say so loudly instead of resuming somebody else's.
            return .init(key: target.key, state: .needsUser, cause: .ambiguousIdentity)
        }

        // Segunda red, ya con la línea completa: la de arriba evita cerrar, esta evita escribir.
        guard let linea = UniConnectRelaunchCommandLine.line(from: argv) else {
            return .init(key: target.key, state: .needsUser, cause: .ambiguousIdentity)
        }
        await driver.type(socket: target.socket, pane: pane, text: linea)
        for _ in 0..<30 {
            await settle()
            let screen = await driver.capture(socket: target.socket, pane: pane) ?? ""
            let reading = dialect.read(screen: screen)
            if reading == .folderTrustQuestion {
                // A permission is answered by a person. The question stays on screen.
                return .init(key: target.key, state: .needsUser, cause: .folderTrust)
            }
            guard reading == .agentReady else { continue }
            // A recycled identifier is not the same process: the start time decides, not the number.
            let replacement = await driver.agent(
                socket: target.socket,
                pane: pane,
                provider: target.provider
            )
            guard case let .found(after) = replacement else { continue }
            // Identidad completa, no un numero: el PID solo se lleva para poder informarlo.
            let proof = RelaunchProcessProof(
                replacedProcess: !after.isSameProcess(as: before),
                before: before.pid,
                after: after.pid
            )
            // La conversacion que se pidio tiene que ser la que el proceso nuevo lleva puesta.
            // Antes se informaba la esperada sin comprobarla; ahora se lee de su linea de comandos,
            // que es la unica fuente que no depende de lo que la pantalla quiera contar.
            guard after.argv.isEmpty || UniConnectRelaunchCommandLine.resumes(conversation, in: after.argv) else {
                return .init(key: target.key, state: .needsUser, cause: .ambiguousIdentity)
            }
            switch dialect.verify(proof: proof, reading: reading) {
            case .success:
                return .init(key: target.key, state: .verified, effectiveID: conversation)
            case let .failure(cause):
                return .init(key: target.key, state: .failed, cause: cause)
            }
        }
        return .init(key: target.key, state: .failed, cause: .unknownDialog)
    }

    /// Walks the pane out of its agent, returning the conversation it printed on the way.
    private func close(
        target: Target,
        pane: String,
        dialect: any RelaunchAgentDialect
    ) async -> Result<String?, RelaunchCause> {
        for _ in 0..<30 {
            let screen = await driver.capture(socket: target.socket, pane: pane) ?? ""
            let reading = dialect.read(screen: screen)
            if case let .exitedShowingResume(sessionID) = reading { return .success(sessionID) }
            switch sequencer.stepToClose(reading: reading) {
            case .done:
                return .success(nil)
            case let .stop(cause):
                return .failure(cause)
            case let .type(text):
                await driver.type(socket: target.socket, pane: pane, text: text)
            case .pressEnter:
                await driver.type(socket: target.socket, pane: pane, text: "")
            }
            await settle()
        }
        return .failure(.unknownDialog)
    }
}
