import Foundation
import Observation

/// State of one open «Detalles» modal: what is saved first, then the live reading when it arrives.
@MainActor
@Observable
final class UniConnectWindowDetailsModel {
    /// The details on screen.
    private(set) var snapshot: UniConnectWindowDetailsSnapshot
    /// Whether the live check is still running («Comprobando…»).
    private(set) var checking = true
    /// Whether the live check failed or timed out, so the modal shows what was saved.
    private(set) var checkFailed = false

    init(snapshot: UniConnectWindowDetailsSnapshot) {
        self.snapshot = snapshot
    }

    /// Replaces the saved view with the live reading, or marks the check as failed.
    func finish(with snapshot: UniConnectWindowDetailsSnapshot, confirmed: Bool) {
        self.snapshot = snapshot
        checking = false
        checkFailed = !confirmed
    }
}
