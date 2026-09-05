import Darwin

extension UniConnectLocalTmuxProcessIdentity {
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
