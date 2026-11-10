import Darwin
import Foundation

/// This Mac's process table through libproc and `sysctl`, never through `ps` text.
///
/// `ps -o args` joins the arguments with spaces, so `--flag "a b"` and `--flag a b` read the same
/// and a relaunch could not give options back faithfully. `KERN_PROCARGS2` hands over the real
/// argv, which is what lets a resume command be quoted argument by argument.
struct UniConnectRelaunchDarwinProcesses: UniConnectRelaunchProcessInspecting {
    private let exitWaiter: any UniConnectProcessExitWaiting

    init(exitWaiter: any UniConnectProcessExitWaiting = UniConnectLocalProcessExitWaiter()) {
        self.exitWaiter = exitWaiter
    }

    func processes() -> [UniConnectRelaunchProcessInfo]? {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return nil }
        var result: [UniConnectRelaunchProcessInfo] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            if let info = info(of: pid) { result.append(info) }
        }
        return result.isEmpty ? nil : result
    }

    private func info(of pid: pid_t) -> UniConnectRelaunchProcessInfo? {
        var bsd = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(size)) == size,
              bsd.pbi_pid == UInt32(pid) else { return nil }
        let name = withUnsafeBytes(of: bsd.pbi_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let start = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
        return UniConnectRelaunchProcessInfo(
            pid: pid, parent: Int32(bsd.pbi_ppid), group: Int32(bsd.pbi_pgid),
            userID: bsd.pbi_uid, start: start, name: name
        )
    }

    func arguments(of pid: Int32) -> (argv: [String], environment: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard buffer.withUnsafeMutableBytes({ sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }) == 0 else {
            return nil
        }
        return UniConnectRelaunchProcArgs(bytes: Array(buffer.prefix(size))).map { ($0.argv, $0.environment) }
    }

    func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    @discardableResult
    func signal(_ signal: Int32, to pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, signal) == 0
    }

    @discardableResult
    func signal(_ signal: Int32, toGroup group: Int32) -> Bool {
        guard group > 1 else { return false }
        return killpg(group, signal) == 0
    }

    func waitForExit(of pid: Int32, timeout: Duration) async -> Bool {
        do {
            try await exitWaiter.waitForExit(processID: pid, timeout: timeout)
            return true
        } catch {
            return kill(pid, 0) == -1 && errno == ESRCH
        }
    }
}
