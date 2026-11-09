import CryptoKit
import Foundation

/// The Linux relaunch worker as it travels to a destination, built exactly like
/// `linux/uniconnect/relaunch_agents.py` (`worker_source`, `worker_bootstrap`, `identity_helper`).
///
/// The Mac does not keep a second implementation of what happens next to a remote pane: it runs
/// the very worker Linux runs, over the box's own SSH (`contracts/relaunch-v1/LEEME.md`, «Mac y
/// SSH»). This type only packs it: the catalogue module in front of the worker, compressed with
/// zlib and base64-encoded into a `python3 -c` bootstrap that stays below per-argument limits.
///
/// ```swift
/// let source = RelaunchWorkerSource(
///     catalogModule: catalogPython, worker: workerPython, identityHook: hookPython, recoveryScript: nil
/// )
/// source.bootstrap  // "import base64,zlib;exec(zlib.decompress(base64.b64decode('eNrs…')))"
/// ```
public struct RelaunchWorkerSource: Sendable, Equatable {
    /// `resume_catalog.py`, then two newlines, then `relaunch_worker.py`.
    public let source: String
    /// The `python3 -c` program that inflates and runs ``source``.
    public let bootstrap: String
    /// `agent_identity_hook.py`, zlib-compressed and base64-encoded (`identity_helper`).
    public let identityHelper: String
    /// SHA-256 of `linux/scripts/recovery.py`, or `nil` when it is not available (`recovery_sha256`).
    public let recoverySHA256: String?

    /// Packs the worker from the texts of its files.
    ///
    /// - Parameters:
    ///   - catalogModule: `linux/uniconnect/resume_catalog.py`.
    ///   - worker: `linux/uniconnect/relaunch_worker.py`.
    ///   - identityHook: `linux/uniconnect/agent_identity_hook.py`.
    ///   - recoveryScript: `linux/scripts/recovery.py`, whose hash lets the worker recognise its
    ///     reviewed launcher; `nil` when absent.
    public init(catalogModule: String, worker: String, identityHook: Data, recoveryScript: Data?) {
        source = catalogModule + "\n\n" + worker
        bootstrap = "import base64,zlib;exec(zlib.decompress(base64.b64decode('"
            + RelaunchZlib().compress(Data(source.utf8)).base64EncodedString() + "')))"
        identityHelper = RelaunchZlib().compress(identityHook).base64EncodedString()
        recoverySHA256 = recoveryScript.map { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}
