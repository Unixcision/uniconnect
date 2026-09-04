import Darwin
import Foundation

/// Identifies the narrowest safe POSIX signal target for one terminal's foreground job.
struct UniConnectSSHProcessTerminationPlan: Equatable, Sendable {
    let foregroundPID: pid_t
    let processGroupID: pid_t?
    let signalTarget: pid_t

    static func make(
        foregroundPID rawPID: UInt64,
        processGroupID rawProcessGroupID: pid_t,
        applicationProcessGroupID: pid_t
    ) -> UniConnectSSHProcessTerminationPlan? {
        guard rawPID > 1, rawPID <= UInt64(Int32.max) else { return nil }
        let foregroundPID = pid_t(rawPID)

        if rawProcessGroupID > 1,
           rawProcessGroupID != applicationProcessGroupID {
            return UniConnectSSHProcessTerminationPlan(
                foregroundPID: foregroundPID,
                processGroupID: rawProcessGroupID,
                signalTarget: -rawProcessGroupID
            )
        }

        // If Ghostty cannot resolve a separate PTY process group, signal only the
        // reported foreground process. Never signal UniConnect's own process group.
        return UniConnectSSHProcessTerminationPlan(
            foregroundPID: foregroundPID,
            processGroupID: nil,
            signalTarget: foregroundPID
        )
    }
}
