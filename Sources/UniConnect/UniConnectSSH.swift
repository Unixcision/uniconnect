import Foundation

// MARK: - Command construction

enum UniConnectSSH {
    /// `claude --resume` only finds a session from the folder it was created in, so the
    /// window always cds first. The folder may be gone (renamed project): fall back to home
    /// instead of leaving the user with a dead shell.
    static func claudeResumeCommandLine(session: String, directory: String?) -> String {
        // `claude --resume` only finds the session from the folder it was created in, so a
        // missing folder must stop the command, not silently resume from $HOME (which fails
        // with a confusing error). The window is left in a usable login shell instead.
        var command = ""
        if let directory, !directory.isEmpty {
            let quoted = singleQuoted(directory)
            command += "if ! cd \(quoted) 2>/dev/null; then "
            command += "echo \"[UniConnect] la carpeta \(quoted) ya no existe; la sesión no se puede reanudar desde aquí\"; "
            command += "exec \"$SHELL\" -l; fi; "
        }
        command += "exec claude --dangerously-skip-permissions --resume \(singleQuoted(session))"
        return command
    }

    /// POSIX single-quoting for a path or argument embedded in a shell command.
    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Options injected right after the `ssh` word so they apply to the client
    /// regardless of whatever wrapper (sshpass, env, etc.) precedes it.
    static let baseClientOptions = [
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ServerAliveInterval=20",
        "-o", "ServerAliveCountMax=3",
        "-o", "ConnectTimeout=15"
    ]

    /// Inserts `options` after the first standalone `ssh` word of a user supplied
    /// connect command. If no `ssh` word is found the options are appended, which
    /// works for thin wrappers that forward their arguments to ssh.
    static func injectingOptions(_ options: [String], into connectCommand: String) -> String {
        let trimmed = connectCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let optionString = options.joined(separator: " ")
        guard !optionString.isEmpty else { return trimmed }
        let pattern = #"(^|\s)((?:\S*/)?ssh)(?=\s)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let sshRange = Range(match.range(at: 2), in: trimmed) {
            var result = trimmed
            result.insert(contentsOf: " " + optionString, at: sshRange.upperBound)
            return result
        }
        return trimmed + " " + optionString
    }

    /// Sanitizes a tmux session name: tmux forbids `.` and `:`; keep it shell-safe too.
    static func sanitizedTmuxName(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var out = ""
        var lastDash = false
        for ch in folded {
            if allowed.contains(ch) {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if out.isEmpty { out = "ventana" }
        return String(out.prefix(40))
    }

    /// Default internal tmux code for a window name: `uc-<slug>-<4 hex>`.
    static func suggestedTmuxName(windowName: String) -> String {
        let slug = sanitizedTmuxName(windowName).lowercased()
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(4)).lowercased()
        return "uc-\(slug)-\(suffix)"
    }

    /// Shell-quotes a string with single quotes.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The remote command that (re)attaches to the named tmux session. `-A` attaches if
    /// it exists, `-D` kicks stale clients (a dead app leaves none, but a lingering one
    /// would otherwise shrink the pane), `-c` seeds the directory on first creation.
    static func remoteTmuxCommand(session: String, directory: String?) -> String {
        var parts = ["tmux", "new-session", "-A", "-D", "-s", shellQuote(session)]
        if let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
            parts += ["-c", shellQuote(directory)]
        }
        // Wheel scrolling inside tmux needs mouse mode; a generous history keeps the
        // scrollback useful. Chained with `\;` so it applies on attach as well as create.
        parts += ["\\;", "set-option", "-g", "mouse", "on", "\\;", "set-option", "-g", "history-limit", "50000"]
        return parts.joined(separator: " ")
    }

    /// Full local command line that opens a terminal tab bound to a tmux session.
    static func attachCommandLine(connectCommand: String, session: String, directory: String?) -> String {
        let client = injectingOptions(["-t"] + baseClientOptions, into: connectCommand)
        // Wrap the remote command in a POSIX shell so a missing tmux still yields a
        // readable message instead of ssh's terse exit.
        let remote = "command -v tmux >/dev/null 2>&1 && exec \(remoteTmuxCommand(session: session, directory: directory)) || { echo '[UniConnect] tmux no está instalado en el servidor'; exec ${SHELL:-sh} -l; }"
        return client + " " + shellQuote(remote)
    }

    /// Writes a self-deleting launcher script (mirrors cmux's restore launchers) so the
    /// command runs through zsh with the user's exact quoting, and returns its path.
    /// Restore-time launchers are spaced out so opening many SSH boxes at once does not
    /// fire dozens of connections in the same instant: each launcher created within a
    /// short window waits a little longer than the previous one (0, 0.4, 0.8… seconds).
    private static var staggerLastAt: TimeInterval = 0
    private static var staggerIndex = 0
    static func nextStaggerDelay() -> Double {
        let now = Date().timeIntervalSince1970
        if now - staggerLastAt > 5 { staggerIndex = 0 }
        staggerLastAt = now
        defer { staggerIndex += 1 }
        return min(Double(staggerIndex) * 0.4, 6)
    }

    static func writeLauncherScript(commandLine: String, label: String, delay: Double = 0) -> String? {
        // Ghostty splits `command` on whitespace, so the launcher must live on a path
        // without spaces: $TMPDIR (per-user, 0700), never "Application Support".
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("uniconnect-launchers", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            pruneOldLaunchers(in: directory)
            let safeLabel = sanitizedTmuxName(label)
            let url = directory.appendingPathComponent("\(safeLabel)-\(UUID().uuidString).zsh")
            let contents = [
                // Login shell: launched from Finder the app inherits a bare PATH, so a plain
                // `#!/bin/zsh` cannot find `claude` (Homebrew, mise, nvm…).
                "#!/bin/zsh -l",
                "rm -f -- \"$0\" 2>/dev/null || true",
                "printf '\\033]0;UniConnect\\007'",
                // Ghostty advertises TERM=xterm-ghostty; most servers lack that terminfo and
                // tmux then refuses to attach ("missing or unsuitable terminal"). ssh forwards
                // TERM, so pin a universally available one for the remote side.
                "export TERM=xterm-256color",
                delay > 0 ? String(format: "sleep %.1f", delay) : ":",
                commandLine,
                ""
            ].joined(separator: "\n")
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url.path
        } catch {
            return nil
        }
    }

    private static func pruneOldLaunchers(in directory: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for item in items {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date < cutoff { try? fm.removeItem(at: item) }
        }
    }

    /// Password-free label for display, e.g. `root@1.2.3.4`.
    static func hostLabel(from connectCommand: String) -> String {
        let pattern = #"([A-Za-z0-9._-]+@)?([A-Za-z0-9.-]+|\[[0-9a-fA-F:]+\])(?=\s|$)"#
        // Shell-aware split, and drop the value of every option that carries a secret or a
        // path: `sshpass -p 'clave'` used to end up in the label, which is persisted in the
        // session snapshot and shown in the sidebar.
        var tokens: [String] = []
        var skipNext = false
        for token in shellWords(connectCommand) {
            if skipNext { skipNext = false; continue }
            if token == "-p" || token == "-i" || token == "-o" || token == "-F" || token == "-P" || token == "-f" {
                skipNext = true
                continue
            }
            // `-p'clave'` / `-i/ruta/clave.pem` glued together.
            if token.hasPrefix("-p") || token.hasPrefix("-i") { continue }
            tokens.append(token)
        }
        // Prefer the token containing '@'; fall back to the last non-option token.
        if let at = tokens.first(where: { $0.contains("@") && !$0.hasPrefix("-") }) { return at }
        if let regex = try? NSRegularExpression(pattern: pattern),
           let last = tokens.last(where: { !$0.hasPrefix("-") && $0 != "ssh" && $0 != "sshpass" }),
           regex.firstMatch(in: last, range: NSRange(last.startIndex..., in: last)) != nil {
            return last
        }
        return "servidor"
    }
}

// MARK: - Server probe: verify / install tmux

final class UniConnectTmuxProbe {
    enum Mode { case check, install }
    enum Outcome {
        case ready(version: String)
        case needsInstall(detail: String)
        case failed(String)
    }

    private var process: Process?
    private let mode: Mode
    private let onLine: (String) -> Void
    private let onFinish: (Outcome) -> Void
    private var sawOK: String?
    private var sawMissing: String?
    private var buffer = ""
    /// Everything the probe printed, used as a safety net when line parsing misses the marker.
    private var rawOutput = ""

    init(mode: Mode = .check, onLine: @escaping (String) -> Void, onFinish: @escaping (Outcome) -> Void) {
        self.mode = mode
        self.onLine = onLine
        self.onFinish = onFinish
    }

    /// Check-only script: reports OS / package manager / sudo situation without touching anything.
    static let checkScript = """
    set -u
    if command -v tmux >/dev/null 2>&1; then
      echo "UC_TMUX_OK $(tmux -V 2>/dev/null)"
      exit 0
    fi
    OS="$(uname -s 2>/dev/null)"
    DISTRO=""
    if [ -r /etc/os-release ]; then DISTRO="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-$ID}")"; fi
    PM="desconocido"
    for c in apt-get dnf yum apk pacman zypper brew; do
      if command -v "$c" >/dev/null 2>&1; then PM="$c"; break; fi
    done
    PERM="root"
    if [ "$(id -u)" != "0" ]; then
      if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then PERM="sudo sin contraseña"; else PERM="SIN permisos de instalación"; fi
    fi
    echo "UC_TMUX_MISSING os=$OS distro=$DISTRO pm=$PM perm=$PERM"
    exit 0
    """

    static let remoteScript = """
    set -u
    if command -v tmux >/dev/null 2>&1; then
      echo "UC_TMUX_OK $(tmux -V 2>/dev/null)"
      exit 0
    fi
    echo "UC_TMUX_MISSING: tmux no está instalado, instalando…"
    SUDO=""
    if [ "$(id -u)" != "0" ]; then
      if command -v sudo >/dev/null 2>&1; then SUDO="sudo -n"; else echo "UC_TMUX_FAIL sin root ni sudo"; exit 1; fi
    fi
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      $SUDO apt-get update -qq 2>&1 | tail -n 5
      $SUDO apt-get install -y -qq tmux 2>&1
    elif command -v dnf >/dev/null 2>&1; then
      $SUDO dnf install -y tmux 2>&1
    elif command -v yum >/dev/null 2>&1; then
      $SUDO yum install -y tmux 2>&1
    elif command -v apk >/dev/null 2>&1; then
      $SUDO apk add --no-cache tmux 2>&1
    elif command -v pacman >/dev/null 2>&1; then
      $SUDO pacman -Sy --noconfirm tmux 2>&1
    elif command -v zypper >/dev/null 2>&1; then
      $SUDO zypper -n install tmux 2>&1
    elif command -v brew >/dev/null 2>&1; then
      brew install tmux 2>&1
    else
      echo "UC_TMUX_FAIL gestor de paquetes desconocido"
      exit 1
    fi
    if command -v tmux >/dev/null 2>&1; then
      echo "UC_TMUX_OK $(tmux -V 2>/dev/null)"
      exit 0
    fi
    echo "UC_TMUX_FAIL la instalación no dejó tmux disponible"
    exit 1
    """

    func start(connectCommand: String) {
        let script = mode == .install ? Self.remoteScript : Self.checkScript
        let client = UniConnectSSH.injectingOptions(["-T"] + UniConnectSSH.baseClientOptions, into: connectCommand)
        let commandLine = client + " " + UniConnectSSH.shellQuote("sh -s")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", commandLine]
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        process.environment = env

        let stdin = Pipe()
        let output = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = output

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self.consume(text) }
        }
        process.terminationHandler = { [weak self] proc in
            // Drain whatever is still in the pipe BEFORE deciding: the marker often arrives
            // in the very last chunk, after the process has already exited. Clearing the
            // handler first stops it from competing for the same bytes.
            output.fileHandleForReading.readabilityHandler = nil
            let remaining = output.fileHandleForReading.availableData
            DispatchQueue.main.async {
                guard let self else { return }
                if !remaining.isEmpty { self.consume(String(decoding: remaining, as: UTF8.self)) }
                self.flushBuffer()
                if let version = self.sawOK {
                    self.onFinish(.ready(version: version))
                } else if let detail = self.sawMissing {
                    self.onFinish(.needsInstall(detail: detail))
                } else if self.rawOutput.contains("UC_TMUX_OK") {
                    self.onFinish(.ready(version: ""))
                } else if self.rawOutput.contains("UC_TMUX_MISSING"), self.mode == .check {
                    self.onFinish(.needsInstall(detail: "tmux no está instalado"))
                } else {
                    self.onFinish(.failed("la conexión terminó con código \(proc.terminationStatus)"))
                }
            }
        }
        self.process = process
        do {
            try process.run()
        } catch {
            onFinish(.failed(error.localizedDescription))
            return
        }
        stdin.fileHandleForWriting.write(Data((script + "\nexit\n").utf8))
        try? stdin.fileHandleForWriting.close()

        DispatchQueue.main.asyncAfter(deadline: .now() + 240) { [weak self] in
            guard let self, let process = self.process, process.isRunning else { return }
            process.terminate()
            self.onFinish(.failed("tiempo de espera agotado"))
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
    }

    private func consume(_ text: String) {
        rawOutput += text
        if rawOutput.count > 200_000 { rawOutput = String(rawOutput.suffix(100_000)) }
        buffer += text
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            handle(line: line)
        }
    }

    private func flushBuffer() {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        if !rest.isEmpty { handle(line: rest) }
    }

    private func handle(line rawLine: String) {
        let line = rawLine.replacingOccurrences(of: "\r", with: "")
        if line.hasPrefix("UC_TMUX_OK") {
            sawOK = line.replacingOccurrences(of: "UC_TMUX_OK", with: "").trimmingCharacters(in: .whitespaces)
            onLine("✓ tmux listo" + (sawOK!.isEmpty ? "" : " (\(sawOK!))"))
            return
        }
        if line.hasPrefix("UC_TMUX_FAIL") {
            onLine("✗ " + line.replacingOccurrences(of: "UC_TMUX_FAIL", with: "").trimmingCharacters(in: .whitespaces))
            return
        }
        if line.hasPrefix("UC_TMUX_MISSING") {
            let detail = line.replacingOccurrences(of: "UC_TMUX_MISSING:", with: "")
                .replacingOccurrences(of: "UC_TMUX_MISSING", with: "").trimmingCharacters(in: .whitespaces)
            if mode == .check { sawMissing = detail.isEmpty ? "tmux no está instalado" : detail }
            onLine("⏳ tmux no está instalado" + (detail.isEmpty ? "" : " (\(detail))"))
            return
        }
        if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            onLine(line)
        }
    }
}


// MARK: - Connect command validation and parsing

extension UniConnectSSH {
    /// Only these executables may start a connect command.
    static let allowedConnectExecutables: Set<String> = ["ssh", "sshpass"]

    /// Minimal shell-words split: single quotes, double quotes and backslash escapes.
    static func shellWords(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasToken = false
        var quote: Character? = nil
        var escaping = false
        for ch in command {
            if escaping {
                current.append(ch); escaping = false; hasToken = true; continue
            }
            if let q = quote {
                if ch == q { quote = nil }
                else if ch == "\\" && q == "\"" { escaping = true }
                else { current.append(ch) }
                continue
            }
            switch ch {
            case "'", "\"":
                quote = ch; hasToken = true
            case "\\":
                escaping = true; hasToken = true
            case " ", "\t", "\n":
                if hasToken { words.append(current); current = ""; hasToken = false }
            default:
                current.append(ch); hasToken = true
            }
        }
        if hasToken { words.append(current) }
        return words
    }

    /// Returns a user-facing error, or nil when the command is acceptable: it must start
    /// with `ssh` or `sshpass` (optionally with a path), and `sshpass` must wrap an `ssh`.
    static func validateConnectCommand(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Pega el comando completo de conexión." }
        if trimmed.contains("\n") { return "El comando no puede tener saltos de línea." }
        let words = shellWords(trimmed)
        guard let first = words.first else { return "Pega el comando completo de conexión." }
        let exe = (first as NSString).lastPathComponent
        guard allowedConnectExecutables.contains(exe) else {
            return "El comando tiene que empezar por `ssh` o `sshpass` (p. ej. `ssh -i clave.pem root@host` o `sshpass -p 'clave' ssh root@host`)."
        }
        if exe == "sshpass" {
            let hasSSH = words.dropFirst().contains { ($0 as NSString).lastPathComponent == "ssh" }
            if !hasSSH { return "Con `sshpass` el comando tiene que invocar `ssh` después de las opciones." }
        }
        if words.count < 2 { return "Falta el destino (usuario@host)." }
        return nil
    }

    /// Builds the SSH session used for remote image paste straight from the stored connect
    /// command (no TTY/process detection).
    static func detectedSession(fromConnectCommand command: String) -> DetectedSSHSession? {
        let words = shellWords(command)
        guard let first = words.first else { return nil }
        let exe = (first as NSString).lastPathComponent
        if exe == "sshpass" {
            return TerminalSSHSessionDetector.parseSshpassCommandLine(words)
        }
        guard let transport = RemoteShellTransport(executableName: exe) else { return nil }
        return TerminalSSHSessionDetector.parseCommandLine(words, for: transport)
    }
}
