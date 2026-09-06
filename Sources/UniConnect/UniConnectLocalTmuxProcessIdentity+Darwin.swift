import Darwin

extension UniConnectLocalTmuxProcessIdentity {
    /// Confirms an idle root shell without treating a failed or incomplete process scan as absence.
    static func isForegroundWithoutChildren(processID: Int) -> Bool {
        guard processID > 1, let pid = pid_t(exactly: processID) else { return false }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_pid == UInt32(pid), info.pbi_pgid > 0,
              info.e_tpgid == info.pbi_pgid else { return false }
        // A real buffer distinguishes zero children from the allocation-size query's padding.
        var children = [pid_t](repeating: 0, count: 1)
        errno = 0
        let count = children.withUnsafeMutableBytes {
            proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
        }
        return count == 0 && errno == 0
    }

    /// Reads one bounded kernel record without inspecting the process's command or credentials.
    init?(processID: Int) {
        guard processID > 1, let pid = pid_t(exactly: processID) else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize)) == expectedSize,
              info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0 else { return nil }
        self.init(
            pid: processID,
            parentPID: Int(info.pbi_ppid),
            userID: info.pbi_uid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }
}
