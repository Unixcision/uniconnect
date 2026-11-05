import Foundation
import Testing
@testable import UniConnectTranscriptRetention

/// Every case of `contracts/transcript-retention-v1/cases.json`, the same ones the Linux
/// edition runs, through the planner.
@Suite struct TranscriptRetentionContractTests {
    struct Case: Decodable, CustomTestStringConvertible {
        struct File: Decodable { let path: String; let age_days: Double }
        let name: String
        let files: [File]
        let protected: [String]
        let compress: [String]
        let delete: [String]
        var testDescription: String { name }
    }

    struct Contract: Decodable {
        struct Policy: Decodable { let compress_after_days: Double; let delete_after_days: Double }
        let policy: Policy
        let cases: [Case]
    }

    static let contract: Contract = {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/" {
            let candidate = folder.appendingPathComponent("contracts/transcript-retention-v1/cases.json")
            if let data = FileManager.default.contents(atPath: candidate.path) {
                // A contract that cannot be read must fail the run, never pass with nothing compared.
                return try! JSONDecoder().decode(Contract.self, from: data)
            }
            folder.deleteLastPathComponent()
        }
        fatalError("contracts/transcript-retention-v1/cases.json not found above \(#filePath)")
    }()

    @Test func thePolicyIsTheOneOfTheContract() {
        let policy = TranscriptRetentionPolicy()
        #expect(policy.compressAfterDays == Self.contract.policy.compress_after_days)
        #expect(policy.deleteAfterDays == Self.contract.policy.delete_after_days)
    }

    @Test(arguments: contract.cases)
    func everyCaseOfTheContract(_ contractCase: Case) {
        let plan = TranscriptRetentionPlanner().plan(
            entries: contractCase.files.map { TranscriptEntry(path: $0.path, ageDays: $0.age_days) },
            protected: Set(contractCase.protected)
        )
        #expect(plan.compress == contractCase.compress.sorted())
        #expect(plan.delete == contractCase.delete.sorted())
    }
}
