import Foundation
import Testing
@testable import CMUXAgentLaunch

/// Las formas de `agent.update` son las de los ejemplos: si discrepan, manda el ejemplo.
@Suite("Contrato de Actualizar Claude")
struct RelaunchUpdateContractTests {
    @Test("Cada objetivo del plan de ejemplo se escribe con las mismas claves")
    func planTargetsHaveTheContractKeys() throws {
        let plan = try ContractFixtures().object("relaunch-v1/plan-update-response.json")
        let targets = try #require(plan["targets"] as? [[String: Any]])
        let base: Set<String> = ["key", "label", "provider", "generation", "state"]
        for target in targets {
            let notes = RelaunchTargetNotes(
                warning: (target["warning"] as? String).flatMap(RelaunchCause.init(rawValue:)),
                background: target["background"] as? Int,
                draft: target["draft"] as? Bool,
                contextTokens: target["context_tokens"] as? Int,
                message: target["message"] as? Bool,
                version: target["version"] as? String,
                installed: target["installed"] as? String
            )
            #expect(Set(notes.json.keys).union(base) == Set(target.keys))
        }
        let estimated = targets.reduce(0) { total, target in
            total + RelaunchTargetNotes(contextTokens: target["context_tokens"] as? Int, message: target["message"] as? Bool).estimatedTokens
        }
        #expect(estimated == plan["estimated_tokens"] as? Int)
        let excluded = try #require(plan["excluded"] as? [[String: String]])
        for exclusion in excluded {
            #expect(RelaunchCause(rawValue: exclusion["cause"] ?? "") != nil)
        }
    }

    @Test("El resultado de ejemplo se escribe con las mismas claves")
    func applyResultsHaveTheContractKeys() throws {
        let apply = try ContractFixtures().object("relaunch-v1/apply-update-response.json")
        let results = try #require(apply["results"] as? [[String: Any]])
        let updates = try #require(apply["updates"] as? [[String: Any]])
        var built: [RelaunchOperation.Result] = []
        for item in results {
            let text = try #require(item["key"] as? String)
            #expect(text.hasPrefix("ssh:root@15.217.153.205:22|tmux:default|pane:%"))
            let key = RelaunchTargetKey(destination: .ssh(user: "root", host: "15.217.153.205", port: 22), tmuxServer: "default",
                                        pane: String(text.split(separator: "|")[2].dropFirst(5)),
                                        generation: Int(text.split(separator: ":").last ?? "") ?? 0)
            #expect(key.text == text)
            var result = RelaunchOperation.Result(key: key, state: .verified, effectiveID: item["effective_id"] as? String)
            result.escalation = (item["escalation"] as? String).flatMap(RelaunchEscalation.init(rawValue:))
            result.version = item["version"] as? String
            result.model = item["model"] as? String
            result.effort = item["effort"] as? String
            result.backgroundSaved = item["background_saved"] as? Int
            result.messageSent = item["message_sent"] as? Bool
            result.draftRestored = item["draft_restored"] as? Bool
            #expect(Set(result.json.keys) == Set(item.keys))
            built.append(result)
        }
        let operationText = try #require(apply["operation_id"] as? String)
        let operation = RelaunchOperation(
            operationID: UUID(uuidString: operationText)!,
            verb: .agentUpdate, recovered: false, results: built,
            updates: updates.map { .init(host: $0["host"] as! String, state: .init(rawValue: $0["state"] as! String)!,
                                         from: $0["from"] as? String, to: $0["to"] as? String) }
        )
        #expect(Set(operation.json.keys) == Set(apply.keys))
        #expect(operation.json["operation_state"] as? String == apply["operation_state"] as? String)
        #expect(Set((operation.json["updates"] as? [[String: Any]])?.first?.keys ?? [:].keys) == Set(updates[0].keys))
    }
}
