import Foundation
import os

/// Salto SSH de `file_put.v1`: ejecuta el mismo `ssh` validado y fijado al endpoint de la caja
/// (`UniConnectSSH.processInvocation`) con el archivo por `stdin` y un script remoto que lo
/// deja en `~/uniconnect-entrada/<nombre>` sin pisar nada: escribe en un nombre temporal y
/// hace `mv -n`, probando `-2`, `-3`… si el definitivo ya existe. Equivale a un `scp` con la
/// misma credencial, pero sin traducir las opciones de `ssh` a las de `scp`.
struct MobileFileSSHCopier: MobileFileRemoteCopying {
    /// Directorio remoto, relativo a `$HOME` del servidor.
    static let remoteDirectory = "uniconnect-entrada"

    // Hosts the one-shot deadline timer; a queue only for timer delivery, never for state.
    private static let timerQueue = DispatchQueue(label: "com.unixcision.uniconnect.mobile.file-put.timer")

    init() {}

    /// Script `sh` que recibe el archivo por stdin y lo coloca sin sobrescribir; imprime la ruta final.
    static func remoteScript(name: MobileFilePutName, nonce: String) -> String {
        let quote = UniConnectSSH.shellQuote
        let temp = quote(".\(name.fileName).\(nonce).part")
        let first = quote(name.candidate(1))
        let stem = quote(name.stem)
        let ext = quote(name.ext)
        return [
            "set -e",
            "d=\"$HOME/\(remoteDirectory)\"",
            "mkdir -p \"$d\"",
            "t=\"$d/\"\(temp)",
            "cat > \"$t\"",
            "i=1",
            "n=\"$d/\"\(first)",
            "while :; do mv -n \"$t\" \"$n\" 2>/dev/null || true; [ -e \"$t\" ] || break; i=$((i+1)); n=\"$d/\"\(stem)\"-$i\"\(ext); done",
            "printf '%s\\n' \"$n\"",
        ].joined(separator: "; ")
    }

    func copy(
        localURL: URL,
        name: MobileFilePutName,
        credentialRecord: UniConnectSSHCredentialRecord,
        timeout: TimeInterval
    ) async -> MobileFileRemoteCopyResult {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        guard let invocation = UniConnectSSH.processInvocation(
            credentialRecord: credentialRecord,
            injecting: ["-T"],
            remoteCommand: Self.remoteScript(name: name, nonce: nonce)
        ) else {
            return .failed(String(
                localized: "uniconnect.ssh.setup.error.missingConnection",
                defaultValue: "The saved connection command could not be found."
            ))
        }
        guard let input = FileHandle(forReadingAtPath: localURL.path) else {
            return .failed(String(localized: "uniconnect.mobile.file.ioFailed", defaultValue: "No se pudo guardar el archivo en el equipo."))
        }
        return await Self.run(invocation: invocation, input: input, timeout: timeout)
    }

    private struct RunState {
        var stdout: Data?
        var stderr: Data?
        var didTerminate = false
        var exitStatus: Int32?
        var resumed = false
        var deadlineTimer: (any DispatchSourceTimer)?
    }

    private static func run(
        invocation: UniConnectSSHProcessInvocation,
        input: FileHandle,
        timeout: TimeInterval
    ) async -> MobileFileRemoteCopyResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.standardInput = input
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let errFD = stderrPipe.fileHandleForReading.fileDescriptor

        return await withCheckedContinuation { (continuation: CheckedContinuation<MobileFileRemoteCopyResult, Never>) in
            // Carve-out de lock: los dos lectores, el terminationHandler y el temporizador corren en
            // callbacks síncronos y compiten por reanudar la continuación exactamente una vez.
            let state = OSAllocatedUnfairLock(initialState: RunState())

            @Sendable func complete(_ mutate: @Sendable (inout RunState) -> Void) {
                let (result, timer): (MobileFileRemoteCopyResult?, (any DispatchSourceTimer)?) = state.withLock { s in
                    mutate(&s)
                    guard !s.resumed, let out = s.stdout, let err = s.stderr, s.didTerminate else { return (nil, nil) }
                    s.resumed = true
                    let timer = s.deadlineTimer
                    s.deadlineTimer = nil
                    return (Self.result(exitStatus: s.exitStatus, stdout: out, stderr: err), timer)
                }
                timer?.cancel()
                if let result { continuation.resume(returning: result) }
            }

            @Sendable func claim(_ result: MobileFileRemoteCopyResult) -> Bool {
                let (won, timer): (Bool, (any DispatchSourceTimer)?) = state.withLock { s in
                    if s.resumed { return (false, nil) }
                    s.resumed = true
                    let timer = s.deadlineTimer
                    s.deadlineTimer = nil
                    return (true, timer)
                }
                timer?.cancel()
                if won { continuation.resume(returning: result) }
                return won
            }

            Task.detached {
                let data = Self.readToEnd(fileDescriptor: outFD)
                complete { $0.stdout = data }
            }
            Task.detached {
                let data = Self.readToEnd(fileDescriptor: errFD)
                complete { $0.stderr = data }
            }
            process.terminationHandler = { finished in
                let status = finished.terminationStatus
                try? input.close()
                complete {
                    $0.didTerminate = true
                    $0.exitStatus = status
                }
            }
            do {
                try process.run()
            } catch {
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                try? input.close()
                _ = claim(.failed(String(describing: error)))
                return
            }
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()

            // Plazo real que debe dispararse aunque el proceso hijo se quede colgado: un temporizador
            // de un disparo fuera de todo contexto async, cancelado al reanudar por cualquier vía.
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                let message = String(localized: "uniconnect.mobile.file.remoteTimeout", defaultValue: "La copia al servidor tardó demasiado.")
                if claim(.failed(message)) {
                    process.terminate()
                }
            }
            let armed = state.withLock { s -> Bool in
                guard !s.resumed else { return false }
                s.deadlineTimer = timer
                return true
            }
            if armed {
                timer.resume()
            } else {
                timer.cancel()
            }
        }
    }

    private static func result(exitStatus: Int32?, stdout: Data, stderr: Data) -> MobileFileRemoteCopyResult {
        let output = String(decoding: stdout, as: UTF8.self)
        let remotePath = output.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if exitStatus == 0, !remotePath.isEmpty {
            return .copied(remotePath: remotePath)
        }
        let error = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = error.isEmpty ? "ssh exit \(exitStatus.map(String.init) ?? "?")" : error
        return .failed(String.localizedStringWithFormat(
            String(localized: "uniconnect.mobile.file.remoteFailed", defaultValue: "No se pudo copiar al servidor: %@"),
            detail
        ))
    }

    private static func readToEnd(fileDescriptor: Int32) -> Data {
        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        return (try? handle.readToEnd()) ?? Data()
    }
}
