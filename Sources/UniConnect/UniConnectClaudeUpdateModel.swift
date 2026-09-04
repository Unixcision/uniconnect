import Foundation
import Observation
import UniConnectClaudeUpdate

/// Main-actor projection of updater preparation, progress, cancellation, and summary state.
@MainActor
@Observable
final class UniConnectClaudeUpdateModel {
    enum Stage: Equatable {
        case preparing
        case confirmation
        case running
        case completed
        case failed
    }

    let scope: ClaudeUpdateScope
    var stage: Stage = .preparing
    var plan: ClaudeUpdatePlan?
    var progress: ClaudeUpdateProgress?
    var summary: ClaudeUpdateSummary?
    var errorMessage: String?
    var cancellationRequestedByUser = false

    init(scope: ClaudeUpdateScope) {
        self.scope = scope
    }

    var targetCount: Int { plan?.targets.count ?? 0 }
    var hostCount: Int { plan?.hosts.count ?? 0 }
    var unresolvedTargetCount: Int {
        plan?.targets.filter { $0.binding == nil || ($0.host.kind == .remote && $0.pane == nil) }.count ?? 0
    }
    var completedTargetCount: Int { progress?.outcomes.count ?? summary?.outcomes.count ?? 0 }
    var completionFraction: Double {
        guard targetCount > 0 else { return 0 }
        return min(1, Double(completedTargetCount) / Double(targetCount))
    }
    var isCancellationRequested: Bool {
        cancellationRequestedByUser || progress?.isCancellationRequested == true
    }
}
