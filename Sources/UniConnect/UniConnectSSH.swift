import Foundation
import UniConnectClaudeBridge

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
            let message = String(
                format: String(
                    localized: "uniconnect.ssh.resume.folderMissing",
                    defaultValue: "The folder %@ no longer exists; this session cannot be resumed from here."
                ),
                directory
            )
            command += "if ! cd \(quoted) 2>/dev/null; then "
            command += "printf '%s\\n' \(shellQuote("[UniConnect] \(message)")); "
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
        "-o", "ConnectTimeout=15",
        "-o", "ForwardAgent=no",
        "-o", "ForwardX11=no",
        "-o", "ForwardX11Trusted=no",
        "-o", "PermitLocalCommand=no"
    ]

    /// Rebuilds a validated connection with trusted absolute executables and safely
    /// quoted arguments. The imported string is never returned or executed verbatim.
    static func injectingOptions(_ options: [String], into connectCommand: String) -> String? {
        UniConnectSSHConnectCommandValidator()
            .validatedCommand(connectCommand)?
            .sensitiveCanonicalShellCommand(injecting: options)
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
        if out.isEmpty { out = "window" }
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

    /// The remote command used only for an explicit new window. `-A` attaches if the
    /// named session exists and otherwise creates it; `-c` seeds that first directory.
    static func remoteTmuxCommand(session: String, directory: String?) -> String {
        // Do not pass `-D`: detaching another client would disrupt terminals outside
        // UniConnect. Restore and reconnect use `remoteRecoverableTmuxCommand` instead.
        var parts = ["tmux", "new-session", "-A", "-s", shellQuote(session)]
        if let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
            parts += ["-c", shellQuote(directory)]
        }
        // Wheel scrolling inside tmux needs mouse mode; a generous history keeps the
        // scrollback useful. Chained with `\;` so it applies on attach as well as create.
        parts += ["\\;", "set-option", "-g", "mouse", "on", "\\;", "set-option", "-g", "history-limit", "50000"]
        return parts.joined(separator: " ")
    }

    /// Restores a saved session atomically, creating it only if its exact name is absent.
    /// Existing panes and clients are preserved; failures leave a usable remote shell.
    static func remoteRecoverableTmuxCommand(session: String, directory: String?) -> String {
        let createOrAttach = remoteTmuxCommand(session: session, directory: nil)
        let operation: String
        if let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
            // Starting the client in the saved directory seeds a newly created session
            // without depending on version-specific handling of -A with -c. Existing
            // panes stay untouched; a vanished directory must not prevent attaching.
            operation = [
                "if cd \(shellQuote(directory)); then",
                "\(createOrAttach);",
                "else",
                "tmux attach-session -t \(shellQuote("=" + session));",
                "fi"
            ].joined(separator: " ")
        } else {
            operation = createOrAttach
        }
        let missingTmuxMessage = String(
            localized: "uniconnect.ssh.tmux.missing",
            defaultValue: "tmux is not installed on the server."
        )
        // Do not exec tmux here: a failed exec would terminate the shell before the
        // fallback can run. A normal tmux detach/exit succeeds and never opens a shell.
        return [
            "if command -v tmux >/dev/null 2>&1; then",
            "\(operation);",
            "else",
            "printf '%s\\n' \(shellQuote("[UniConnect] \(missingTmuxMessage)")) >&2;",
            "false;",
            "fi || exec \"${SHELL:-/bin/sh}\" -l"
        ].joined(separator: " ")
    }

    /// Strictly attaches to an existing exact name for import and validation flows.
    /// This path deliberately cannot create a replacement for a missing session.
    static func remoteExistingTmuxCommand(session: String) -> String {
        let target = shellQuote("=" + session)
        let missingTmuxMessage = String(
            localized: "uniconnect.ssh.tmux.missing",
            defaultValue: "tmux is not installed on the server."
        )
        let missingSessionFormat = String(
            localized: "uniconnect.ssh.tmux.savedSessionMissing",
            defaultValue: "The saved tmux session “%@” no longer exists."
        )
        let missingSessionMessage = String(
            format: missingSessionFormat,
            locale: Locale.current,
            session
        )
        return [
            "if ! command -v tmux >/dev/null 2>&1; then",
            "printf '%s\\n' \(shellQuote("[UniConnect] \(missingTmuxMessage)")) >&2;",
            "exit 127;",
            "fi;",
            "if ! tmux has-session -t \(target) 2>/dev/null; then",
            "printf '%s\\n' \(shellQuote("[UniConnect] \(missingSessionMessage)")) >&2;",
            "exit 72;",
            "fi;",
            "tmux set-option -g mouse on >/dev/null 2>&1 || true;",
            "tmux set-option -g history-limit 50000 >/dev/null 2>&1 || true;",
            "exec tmux attach-session -t \(target)"
        ].joined(separator: " ")
    }

    /// Full local command line that opens a terminal tab bound to a tmux session.
    static func attachCommandLine(
        connectCommand: String,
        session: String,
        directory: String?,
        bridge: ClaudeBridgeConnectionPlan? = nil,
        existingSessionOnly: Bool = false,
        recoverMissingSession: Bool = false,
        effectiveTarget: UniConnectSSHEffectiveTarget? = nil
    ) -> String? {
        let options = ["-t"] + baseClientOptions + (bridge?.sshOptions ?? [])
        let tmux: String
        if recoverMissingSession {
            tmux = remoteRecoverableTmuxCommand(session: session, directory: directory)
        } else if existingSessionOnly {
            tmux = remoteExistingTmuxCommand(session: session)
        } else {
            // Explicitly creating a new SSH window keeps create-or-attach semantics. A
            // missing tmux still yields a readable shell instead of ssh's terse exit.
            let message = String(
                localized: "uniconnect.ssh.tmux.missing",
                defaultValue: "tmux is not installed on the server."
            )
            tmux = "command -v tmux >/dev/null 2>&1 && exec \(remoteTmuxCommand(session: session, directory: directory)) || { printf '%s\\n' \(shellQuote("[UniConnect] \(message)")) >&2; exec ${SHELL:-sh} -l; }"
        }
        let remote = bridge.map { $0.remoteSetupCommand + "; " + tmux } ?? tmux
        guard let validated = UniConnectSSHConnectCommandValidator()
            .validatedCommand(connectCommand) else {
            return nil
        }
        if let effectiveTarget {
            return validated.sensitiveCanonicalShellCommand(
                injecting: options,
                pinnedTo: effectiveTarget,
                remoteCommand: remote
            )
        }
        return validated.sensitiveCanonicalShellCommand(
            injecting: options,
            remoteCommand: remote
        )
    }

    /// Builds an SSH/tmux launcher from one complete encrypted credential revision.
    /// Legacy command-only records fail closed until their endpoint is migrated.
    static func attachCommandLine(
        credentialRecord: UniConnectSSHCredentialRecord,
        session: String,
        directory: String?,
        bridge: ClaudeBridgeConnectionPlan? = nil,
        existingSessionOnly: Bool = false,
        recoverMissingSession: Bool = false
    ) -> String? {
        guard let effectiveTarget = credentialRecord.effectiveTarget else { return nil }
        return attachCommandLine(
            connectCommand: credentialRecord.connectCommand,
            session: session,
            directory: directory,
            bridge: bridge,
            existingSessionOnly: existingSessionOnly,
            recoverMissingSession: recoverMissingSession,
            effectiveTarget: effectiveTarget
        )
    }

    /// Constructs a shell-free SSH subprocess pinned to the record's saved endpoint.
    static func processInvocation(
        credentialRecord: UniConnectSSHCredentialRecord,
        injecting options: [String] = [],
        remoteCommand: String? = nil,
        ambientEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UniConnectSSHProcessInvocation? {
        guard let effectiveTarget = credentialRecord.effectiveTarget,
              let invocation = UniConnectSSHConnectCommandValidator()
                .validatedCommand(credentialRecord.connectCommand)?
                .invocation(
                    injecting: options,
                    pinnedTo: effectiveTarget,
                    remoteCommand: remoteCommand,
                    ambientEnvironment: ambientEnvironment
                ) else {
            return nil
        }
        return UniConnectSSHProcessInvocation(
            executable: invocation.executable,
            arguments: invocation.arguments,
            environment: invocation.environment
        )
    }

    /// Writes a self-deleting launcher script for an already canonicalized command and
    /// returns its path. Imported shell text must never be passed to this method directly.
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
                "export HOME=\(shellQuote(FileManager.default.homeDirectoryForCurrentUser.path))",
                // ProxyJump may start a nested ssh client. Keep that lookup on Apple's
                // trusted system path rather than inheriting a login-shell PATH entry.
                "export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                // Do not let ambient launch helpers, dynamic-loader overrides, or a stale
                // password variable influence the trusted executables below. A password
                // connection sets a command-scoped SSHPASS assignment on its final line.
                "unset SSHPASS SSH_ASKPASS SSH_ASKPASS_REQUIRE DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH LD_PRELOAD",
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

    /// Creates a readable local placeholder when restore detects another live owner for
    /// the same endpoint/tmux target. It never invokes ssh or creates a remote session.
    static func duplicateTargetPlaceholderLauncher(session: String) -> String? {
        let message = String(
            localized: "uniconnect.ssh.window.restoreDuplicate",
            defaultValue: "This saved SSH/tmux window was not attached because the same remote target is already open. Close the other owner, then reconnect this window."
        )
        let quotedMessage = shellQuote("[UniConnect] \(message)")
        let command = "printf '%s\\n' \(quotedMessage) >&2; exit 75"
        return writeLauncherScript(commandLine: command, label: session)
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
        // Derive labels from the same validated representation used to launch. This avoids
        // ever scanning a password-bearing wrapper for a plausible-looking host token.
        return UniConnectSSHConnectCommandValidator()
            .validatedCommand(connectCommand)?
            .detectedSession()?
            .destination
            ?? String(localized: "uniconnect.ssh.hostFallback", defaultValue: "server")
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
    PM="unknown"
    for c in apt-get dnf yum apk pacman zypper brew; do
      if command -v "$c" >/dev/null 2>&1; then PM="$c"; break; fi
    done
    PERM="root"
    if [ "$(id -u)" != "0" ]; then
      if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then PERM="passwordless-sudo"; else PERM="no-install-permission"; fi
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
    echo "UC_TMUX_MISSING"
    SUDO=""
    if [ "$(id -u)" != "0" ]; then
      if command -v sudo >/dev/null 2>&1; then SUDO="sudo -n"; else echo "UC_TMUX_FAIL NO_PRIVILEGES"; exit 1; fi
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
      echo "UC_TMUX_FAIL UNKNOWN_PACKAGE_MANAGER"
      exit 1
    fi
    if command -v tmux >/dev/null 2>&1; then
      echo "UC_TMUX_OK $(tmux -V 2>/dev/null)"
      exit 0
    fi
    echo "UC_TMUX_FAIL INSTALL_INCOMPLETE"
    exit 1
    """

    func start(credentialRecord: UniConnectSSHCredentialRecord) {
        let script = mode == .install ? Self.remoteScript : Self.checkScript
        guard let invocation = UniConnectSSH.processInvocation(
            credentialRecord: credentialRecord,
            injecting: ["-T"] + UniConnectSSH.baseClientOptions,
            remoteCommand: "sh -s"
        ) else {
            onFinish(.failed(
                UniConnectSSH.validateConnectCommand(credentialRecord.connectCommand) ?? String(
                    localized: "uniconnect.ssh.probe.error.launchUnavailable",
                    defaultValue: "The SSH connection could not be started."
                )
            ))
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        var env = invocation.environment
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
                    self.onFinish(.needsInstall(detail: String(
                        localized: "uniconnect.ssh.probe.tmuxMissing",
                        defaultValue: "tmux is not installed"
                    )))
                } else {
                    self.onFinish(.failed(String(
                        format: String(
                            localized: "uniconnect.ssh.probe.error.terminated",
                            defaultValue: "The connection ended with status %d."
                        ),
                        proc.terminationStatus
                    )))
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
            self.onFinish(.failed(String(
                localized: "uniconnect.ssh.probe.error.timedOut",
                defaultValue: "The connection timed out."
            )))
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
            let ready = String(localized: "uniconnect.ssh.probe.tmuxReady", defaultValue: "tmux is ready")
            onLine("✓ \(ready)" + (sawOK!.isEmpty ? "" : " (\(sawOK!))"))
            return
        }
        if line.hasPrefix("UC_TMUX_FAIL") {
            let code = line.replacingOccurrences(of: "UC_TMUX_FAIL", with: "").trimmingCharacters(in: .whitespaces)
            let message: String
            switch code {
            case "NO_PRIVILEGES":
                message = String(
                    localized: "uniconnect.ssh.probe.error.noPrivileges",
                    defaultValue: "Administrator privileges are unavailable on the server."
                )
            case "UNKNOWN_PACKAGE_MANAGER":
                message = String(
                    localized: "uniconnect.ssh.probe.error.unknownPackageManager",
                    defaultValue: "No supported package manager was found on the server."
                )
            case "INSTALL_INCOMPLETE":
                message = String(
                    localized: "uniconnect.ssh.probe.error.installIncomplete",
                    defaultValue: "tmux is still unavailable after installation."
                )
            default:
                message = code
            }
            onLine("✗ " + message)
            return
        }
        if line.hasPrefix("UC_TMUX_MISSING") {
            let detail = line.replacingOccurrences(of: "UC_TMUX_MISSING:", with: "")
                .replacingOccurrences(of: "UC_TMUX_MISSING", with: "").trimmingCharacters(in: .whitespaces)
            let missing = String(
                localized: "uniconnect.ssh.probe.tmuxMissing",
                defaultValue: "tmux is not installed"
            )
            if mode == .check { sawMissing = detail.isEmpty ? missing : detail }
            onLine("⏳ \(missing)" + (detail.isEmpty ? "" : " (\(detail))"))
            return
        }
        if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            onLine(line)
        }
    }
}


// MARK: - Connect command validation and parsing

extension UniConnectSSH {
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

    /// Returns a user-facing error, or nil when the command is one safe SSH invocation.
    static func validateConnectCommand(_ command: String) -> String? {
        switch UniConnectSSHConnectCommandValidator().validate(command) {
        case nil:
            return nil
        case .empty:
            return String(
                localized: "uniconnect.ssh.validation.empty",
                defaultValue: "Paste the complete connection command."
            )
        case .lineBreak:
            return String(
                localized: "uniconnect.ssh.validation.lineBreak",
                defaultValue: "The command cannot contain line breaks."
            )
        case .invalidSSHPasswordWrapper:
            return String(
                localized: "uniconnect.ssh.validation.invalidSSHPasswordWrapper",
                defaultValue: "With `sshpass`, the command must invoke `ssh` after the options."
            )
        case .missingDestination:
            return String(
                localized: "uniconnect.ssh.validation.missingDestination",
                defaultValue: "The destination (user@host) is missing."
            )
        case .malformedQuoting, .unsafeShellSyntax, .unsupportedExecutable,
             .unsupportedSSHOption, .unsafeSSHOption, .invalidDestination, .remoteCommand:
            return String(
                localized: "uniconnect.ssh.validation.unsupportedCommand",
                defaultValue: "The command must start with `ssh` or `sshpass` (for example, `ssh -i key.pem root@host` or `sshpass -p 'password' ssh root@host`)."
            )
        }
    }

    /// Builds the SSH session used for remote image paste straight from the stored connect
    /// command (no TTY/process detection).
    static func detectedSession(fromConnectCommand command: String) -> DetectedSSHSession? {
        UniConnectSSHConnectCommandValidator()
            .validatedCommand(command)?
            .detectedSession()
    }

    /// Derives upload metadata while retaining the vault's immutable endpoint pin.
    static func detectedSession(
        fromCredentialRecord record: UniConnectSSHCredentialRecord
    ) -> DetectedSSHSession? {
        guard let effectiveTarget = record.effectiveTarget,
              var session = detectedSession(fromConnectCommand: record.connectCommand) else {
            return nil
        }
        session.uniConnectEffectiveTarget = effectiveTarget
        return session
    }
}
