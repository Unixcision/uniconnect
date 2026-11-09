import Foundation
import Testing
@testable import CMUXAgentLaunch

/// `agent.update` cambia modelo y effort; `agent.relaunch` no cambia nada.
@Suite("Opciones de Actualizar Claude")
struct RelaunchUpdateOptionsTests {
    @Test("Las del contrato valen y salen como --model y --effort")
    func contractOptionsAreValid() throws {
        let request = try ContractFixtures().object("relaunch-v1/plan-update-request.json")
        let verbText = try #require(request["verb"] as? String)
        let verb = try #require(RelaunchVerb(rawValue: verbText))
        let options = try RelaunchUpdateOptions.parse(request["options"], verb: verb)
        #expect(options.model == "fable[1m]")
        #expect(options.effort == .medium)
        #expect(options.arguments == ["--model", "fable[1m]", "--effort", "medium"])
        #expect(options.json == ["model": "fable[1m]", "effort": "medium"])
    }

    @Test("Sin opciones es «igual que estaba»")
    func absentMeansUnchanged() throws {
        #expect(try RelaunchUpdateOptions.parse(nil, verb: .agentUpdate).isUnchanged)
        #expect(try RelaunchUpdateOptions.parse(nil, verb: .agentRelaunch).isUnchanged)
        #expect(try RelaunchUpdateOptions.parse(["effort": "high"], verb: .agentUpdate).model == nil)
    }

    @Test("Relanzar con opciones es opciones_no_validas")
    func relaunchRefusesOptions() {
        #expect(throws: RelaunchError.invalidOptions) {
            try RelaunchUpdateOptions.parse(["model": "opus[1m]"], verb: .agentRelaunch)
        }
    }

    @Test("Modelo o effort mal escritos, o claves de más, se rechazan", arguments: [
        ["model": "Opus 5"], ["model": "x"], ["model": "opus;rm -rf"], ["effort": "ultra"],
        ["model": "opus", "temperature": "1"], ["model": 5],
    ] as [[String: any Sendable]])
    func malformedOptionsAreRefused(_ options: [String: any Sendable]) {
        #expect(throws: RelaunchError.invalidOptions) {
            try RelaunchUpdateOptions.parse(options, verb: .agentUpdate)
        }
    }

    @Test("El error es el del contrato")
    func errorCodeIsTheContracts() throws {
        let errors = try ContractFixtures().object("relaunch-v1/errors.json")
        #expect(errors[RelaunchError.invalidOptions.rawValue] != nil)
        for error in [RelaunchError.tokenExpired, .tokenInvalid, .unknownOperation, .invalidScope, .invalidOptions] {
            #expect(errors[error.rawValue] != nil, "\(error.rawValue) no está en errors.json")
        }
    }
}
