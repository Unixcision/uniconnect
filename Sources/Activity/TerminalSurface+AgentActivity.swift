import Darwin
import Foundation

extension TerminalSurface {
    /// Nombre del proceso en primer plano de la PTY (`claude`, `node`, `zsh`…).
    ///
    /// Devuelve `nil` sin superficie viva o sin proceso; para ventanas con tmux local el
    /// resultado es `tmux` y la sonda de tmux aporta el comando real del panel.
    @MainActor
    func agentActivityForegroundCommand() -> String? {
        guard let runtimeSurface = liveSurfaceForGhosttyAccess(reason: "agentActivityForegroundCommand") else {
            return nil
        }
        let foregroundPID = ghostty_surface_foreground_pid(runtimeSurface)
        guard foregroundPID > 0, foregroundPID <= UInt64(Int32.max) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) + 1)
        let length = proc_name(pid_t(foregroundPID), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let name = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
