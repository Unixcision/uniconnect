public import CmuxProcess
public import Foundation

/// ``TranscriptCompressing`` with the system's `gzip`, which streams files of any size.
///
/// A transcript can be gigabytes, so nothing is read into memory here: `gzip` reads the file and
/// the shell appends its output.
public struct GzipTranscriptCompressor: TranscriptCompressing {
    private let runner: any CommandRunning
    private let gzipPath: String
    private let timeout: TimeInterval

    /// Creates a compressor.
    /// - Parameters:
    ///   - runner: runs `gzip`; tests can pass a fake.
    ///   - gzipPath: the `gzip` binary; `/usr/bin/gzip` exists on every macOS.
    ///   - timeout: seconds allowed per file; a 2 GB transcript takes about a minute.
    public init(runner: any CommandRunning = CommandRunner(), gzipPath: String = "/usr/bin/gzip", timeout: TimeInterval = 1800) {
        self.runner = runner
        self.gzipPath = gzipPath
        self.timeout = timeout
    }

    public func append(_ source: URL, to destination: URL) async -> Bool {
        let result = await runner.run(
            directory: "/",
            executable: "/bin/sh",
            arguments: ["-c", "exec \"$0\" -6 -c -- \"$1\" >> \"$2\"", gzipPath, source.path, destination.path],
            timeout: timeout
        )
        return result.succeeded
    }

    public func verify(_ archive: URL) async -> Bool {
        await runner.run(directory: "/", executable: gzipPath, arguments: ["-t", "--", archive.path], timeout: timeout).succeeded
    }
}

private extension CommandResult {
    var succeeded: Bool { executionError == nil && !timedOut && exitStatus == 0 }
}
