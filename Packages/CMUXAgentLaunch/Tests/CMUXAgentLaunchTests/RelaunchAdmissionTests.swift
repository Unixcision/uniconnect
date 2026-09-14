import Foundation
import Testing
@testable import CMUXAgentLaunch

/// The awkward cases of `relaunch.apply`: what executes, what is recovered, and what is refused.
@Suite("Admisión de relanzados")
struct RelaunchAdmissionTests {
    private let device = "pixel-de-dani"
    private let operationID = UUID()

    private func key(_ pane: String, generation: Int) -> RelaunchTargetKey {
        RelaunchTargetKey(
            destination: .ssh(user: "root", host: "185.237.235.117", port: 22),
            tmuxServer: "uniconnect",
            pane: pane,
            generation: generation
        )
    }

    private func token(
        targets: Set<RelaunchTargetKey>,
        expiresAt: Date,
        deviceID: String? = nil
    ) -> RelaunchToken {
        RelaunchToken(
            deviceID: deviceID ?? device,
            operationID: operationID,
            verb: .agentRelaunch,
            targets: targets,
            expiresAt: expiresAt
        )
    }

    private func live(_ keys: [RelaunchTargetKey]) -> [String: RelaunchTargetKey] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0.paneIdentity, $0) })
    }

    @Test("Un apply nuevo con token vigente ejecuta lo planeado")
    func freshApplyRuns() {
        let a = key("%1", generation: 3)
        let now = Date(timeIntervalSince1970: 1_000)
        let outcome = RelaunchAdmissionGate().admit(
            token: token(targets: [a], expiresAt: now.addingTimeInterval(60)),
            requestedBy: device,
            knownOperations: [:],
            liveTargets: live([a]),
            now: now
        )
        #expect(outcome == .execute(targets: [a], excluded: []))
    }

    @Test("Un apply nuevo con el token caducado no ejecuta nada")
    func expiredFreshApplyIsRefused() {
        let a = key("%1", generation: 3)
        let now = Date(timeIntervalSince1970: 1_000)
        let outcome = RelaunchAdmissionGate().admit(
            token: token(targets: [a], expiresAt: now.addingTimeInterval(-1)),
            requestedBy: device,
            knownOperations: [:],
            liveTargets: live([a]),
            now: now
        )
        #expect(outcome == .reject(.tokenExpired))
    }

    @Test("Recuperar una operación ya aceptada vale aunque el token haya caducado")
    func recoveryIgnoresExpiry() {
        // Se cerró la IA, se cortó la red antes de la respuesta, y el reintento llega tarde.
        // Exigir un plan nuevo aquí convertiría ese corte en trabajo perdido.
        let a = key("%1", generation: 3)
        let now = Date(timeIntervalSince1970: 1_000)
        let outcome = RelaunchAdmissionGate().admit(
            token: token(targets: [a], expiresAt: now.addingTimeInterval(-500)),
            requestedBy: device,
            knownOperations: [operationID: .init(deviceID: device)],
            liveTargets: live([a]),
            now: now
        )
        #expect(outcome == .recover(operationID: operationID))
    }

    @Test("Pero la excepción es solo a la caducidad: un token viejo no es una llave maestra")
    func recoveryStillChecksOwnership() {
        let a = key("%1", generation: 3)
        let now = Date(timeIntervalSince1970: 1_000)
        let gate = RelaunchAdmissionGate()
        let expired = token(targets: [a], expiresAt: now.addingTimeInterval(-500))

        // Otro dispositivo presentando el token de esta operación.
        #expect(gate.admit(
            token: expired, requestedBy: "movil-ajeno",
            knownOperations: [operationID: .init(deviceID: device)],
            liveTargets: live([a]), now: now
        ) == .reject(.tokenInvalid))

        // El dueño correcto, pero el token fue emitido a otro.
        #expect(gate.admit(
            token: token(targets: [a], expiresAt: now.addingTimeInterval(-500), deviceID: "otro"),
            requestedBy: device,
            knownOperations: [operationID: .init(deviceID: device)],
            liveTargets: live([a]), now: now
        ) == .reject(.tokenInvalid))
    }

    @Test("Un objetivo cuya generación cambió se deja fuera y el resto sigue")
    func changedGenerationIsDroppedNotRun() {
        // Entre el plan y el apply, otra IA ocupó ese panel. Relanzarlo sería relanzar a un extraño.
        let planned = key("%1", generation: 3)
        let other = key("%2", generation: 9)
        let now = Date(timeIntervalSince1970: 1_000)
        let outcome = RelaunchAdmissionGate().admit(
            token: token(targets: [planned, other], expiresAt: now.addingTimeInterval(60)),
            requestedBy: device,
            knownOperations: [:],
            liveTargets: live([key("%1", generation: 4), other]),
            now: now
        )
        #expect(outcome == .execute(targets: [other], excluded: [(planned, .generationChanged)]))
    }

    @Test("Un panel que ya no existe tampoco se toca")
    func vanishedPaneIsDropped() {
        let gone = key("%1", generation: 3)
        let now = Date(timeIntervalSince1970: 1_000)
        let outcome = RelaunchAdmissionGate().admit(
            token: token(targets: [gone], expiresAt: now.addingTimeInterval(60)),
            requestedBy: device,
            knownOperations: [:],
            liveTargets: [:],
            now: now
        )
        #expect(outcome == .execute(targets: [], excluded: [(gone, .generationChanged)]))
    }
}
