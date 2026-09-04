import Darwin
import Foundation

extension TerminalSurface {
    /// Immediately asks the foreground SSH job to terminate, then applies a bounded
    /// SIGKILL fallback without delaying creation of the replacement surface.
    @MainActor
    @discardableResult
    func uniConnectTerminateForegroundProcessForForcedSSHReconnect(
        killAfterNanoseconds: UInt64 = 750_000_000
    ) -> UniConnectSSHProcessTerminationPlan? {
        guard let runtimeSurface = surface else { return nil }
        let foregroundPID = ghostty_surface_foreground_pid(runtimeSurface)
        guard foregroundPID <= UInt64(Int32.max) else { return nil }

        let pid = pid_t(foregroundPID)
        let processGroupID = pid > 1 ? Darwin.getpgid(pid) : -1
        guard let plan = UniConnectSSHProcessTerminationPlan.make(
            foregroundPID: foregroundPID,
            processGroupID: processGroupID,
            applicationProcessGroupID: Darwin.getpgrp()
        ) else { return nil }

        let termResult = Darwin.kill(plan.signalTarget, SIGTERM)
        guard termResult == 0 || errno == ESRCH else { return nil }

        Task.detached(priority: .userInitiated) {
            do {
                try await Task.sleep(nanoseconds: killAfterNanoseconds)
            } catch {
                return
            }

            if let expectedProcessGroupID = plan.processGroupID {
                // A surviving process in the original PTY job group is the exact hung
                // connection we own. The newly spawned surface receives a different group.
                guard Darwin.kill(-expectedProcessGroupID, 0) == 0 || errno == EPERM else {
                    return
                }
            } else {
                guard Darwin.kill(plan.foregroundPID, 0) == 0 || errno == EPERM else {
                    return
                }
            }
            _ = Darwin.kill(plan.signalTarget, SIGKILL)
        }

        return plan
    }
}
