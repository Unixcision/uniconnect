import Foundation

/// An explicit set of safe workspace mutations chosen from one preview.
struct UniConnectImportSelection: Equatable, Sendable {
    enum ValidationError: Error, Equatable {
        case unknownOrUnselectableRows(Set<Int>)
    }

    let rowIDs: Set<Int>

    init(rowIDs: Set<Int>, plan: UniConnectImportPlan) throws {
        let selectable = Set(plan.mutationRows.map(\.id))
        let invalid = rowIDs.subtracting(selectable)
        guard invalid.isEmpty else {
            throw ValidationError.unknownOrUnselectableRows(invalid)
        }
        self.rowIDs = rowIDs
    }

    static func allMutations(in plan: UniConnectImportPlan) -> UniConnectImportSelection {
        // This cannot fail because the IDs come from the same immutable plan.
        try! UniConnectImportSelection(rowIDs: plan.defaultSelectedRowIDs, plan: plan)
    }
}
