import Foundation

enum RemoteInteractiveShellBootstrapBuilder {
    static func script(
        remoteRelayPort: Int,
        bridgeHostID: String? = nil,
        shellFeatures: String,
        terminfoSource: String? = nil,
        bundledZshIntegration: String? = nil,
        bundledBashIntegration: String? = nil,
        bundledClaudeWrapper: String? = nil
    ) -> String {
        let shellStateDir = shellStateDirForRemoteRelayPort(remoteRelayPort)
        let commonShellExportLines = commonShellLines(
            remoteRelayPort: remoteRelayPort,
            bridgeHostID: bridgeHostID,
            shellStateDir: shellStateDir,
            shellFeatures: shellFeatures,
            terminfoSource: terminfoSource
        )
        var zshShellLines = commonShellExportLines
        zshShellLines.append(
            #"if [ "${CMUX_SHELL_INTEGRATION:-1}" != "0" ] && [ -r "${CMUX_SHELL_INTEGRATION_DIR}/uniconnect-zsh-integration.zsh" ]; then . "${CMUX_SHELL_INTEGRATION_DIR}/uniconnect-zsh-integration.zsh"; fi"#
        )
        var bashShellLines = commonShellExportLines
        bashShellLines.append(
            #"if [ "${CMUX_SHELL_INTEGRATION:-1}" != "0" ] && [ -r "${CMUX_SHELL_INTEGRATION_DIR}/uniconnect-bash-integration.bash" ]; then . "${CMUX_SHELL_INTEGRATION_DIR}/uniconnect-bash-integration.bash"; fi"#
        )
        let zshBootstrap = RemoteRelayZshBootstrap(shellStateDir: shellStateDir)
        let relayWarmupLines = relayWarmupLines(remoteRelayPort: remoteRelayPort)

        var outerLines: [String] = [
            "mkdir -p \"$HOME/.uniconnect/relay\"",
            "cmux_shell_dir=\"\(shellStateDir)\"",
            "mkdir -p \"$cmux_shell_dir\"",
        ]
        if let bundledZshIntegration {
            outerLines += [
                "cat > \"$cmux_shell_dir/uniconnect-zsh-integration.zsh\" <<'CMUXCMUXZSH'",
                bundledZshIntegration,
                "CMUXCMUXZSH",
            ]
        }
        if let bundledBashIntegration {
            outerLines += [
                "cat > \"$cmux_shell_dir/uniconnect-bash-integration.bash\" <<'CMUXCMUXBASH'",
                bundledBashIntegration,
                "CMUXCMUXBASH",
            ]
        }
        if let bundledClaudeWrapper {
            outerLines += [
                "mkdir -p \"$cmux_shell_dir/bin\"",
                "cat > \"$cmux_shell_dir/bin/uniconnect-claude-wrapper\" <<'UNICONNECTCLAUDEWRAPPER'",
                bundledClaudeWrapper,
                "UNICONNECTCLAUDEWRAPPER",
                "chmod 700 \"$cmux_shell_dir/bin/uniconnect-claude-wrapper\"",
            ]
        }
        outerLines.append(contentsOf: commonShellExportLines)
        outerLines += [
            "CMUX_LOGIN_SHELL=\"${SHELL:-/bin/zsh}\"",
            "case \"${CMUX_LOGIN_SHELL##*/}\" in",
            "  zsh)",
            "    cat > \"$cmux_shell_dir/.zshenv\" <<'CMUXZSHENV'",
        ]
        outerLines.append(contentsOf: zshBootstrap.zshEnvLines)
        outerLines += [
            "CMUXZSHENV",
            "    cat > \"$cmux_shell_dir/.zprofile\" <<'CMUXZSHPROFILE'",
        ]
        outerLines.append(contentsOf: zshBootstrap.zshProfileLines)
        outerLines += [
            "CMUXZSHPROFILE",
            "    cat > \"$cmux_shell_dir/.zshrc\" <<'CMUXZSHRC'",
        ]
        outerLines.append(contentsOf: zshBootstrap.zshRCLines(commonShellLines: zshShellLines))
        outerLines += [
            "CMUXZSHRC",
            "    cat > \"$cmux_shell_dir/.zlogin\" <<'CMUXZSHLOGIN'",
        ]
        outerLines.append(contentsOf: zshBootstrap.zshLoginLines)
        outerLines += [
            "CMUXZSHLOGIN",
            "    chmod 600 \"$cmux_shell_dir/.zshenv\" \"$cmux_shell_dir/.zprofile\" \"$cmux_shell_dir/.zshrc\" \"$cmux_shell_dir/.zlogin\" >/dev/null 2>&1 || true",
        ]
        outerLines.append(contentsOf: relayWarmupLines.map { "    " + $0 })
        outerLines += [
            "    export CMUX_REAL_ZDOTDIR=\"${ZDOTDIR:-$HOME}\"",
            "    export ZDOTDIR=\"$cmux_shell_dir\"",
            "    exec \"$CMUX_LOGIN_SHELL\" -il",
            "    ;;",
            "  bash)",
            "    cat > \"$cmux_shell_dir/.bashrc\" <<'CMUXBASHRC'",
        ]
        outerLines.append(contentsOf: [
            "if [ -f \"$HOME/.bash_profile\" ]; then",
            "  . \"$HOME/.bash_profile\"",
            "elif [ -f \"$HOME/.bash_login\" ]; then",
            "  . \"$HOME/.bash_login\"",
            "elif [ -f \"$HOME/.profile\" ]; then",
            "  . \"$HOME/.profile\"",
            "fi",
            "[ -f \"$HOME/.bashrc\" ] && . \"$HOME/.bashrc\"",
        ] + bashShellLines)
        outerLines += [
            "CMUXBASHRC",
            "    chmod 600 \"$cmux_shell_dir/.bashrc\" >/dev/null 2>&1 || true",
        ]
        outerLines.append(contentsOf: relayWarmupLines.map { "    " + $0 })
        outerLines += [
            "    exec \"$CMUX_LOGIN_SHELL\" --rcfile \"$cmux_shell_dir/.bashrc\" -i",
            "    ;;",
            "  *)",
        ]
        outerLines.append(contentsOf: relayWarmupLines)
        outerLines += [
            "exec \"$CMUX_LOGIN_SHELL\" -i",
            ";;",
            "esac",
        ]

        return outerLines.joined(separator: "\n")
    }

    static func shellFeatures(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let rawExisting = environment["GHOSTTY_SHELL_FEATURES"] ?? ""
        var seen: Set<String> = []
        var merged: [String] = []

        for token in rawExisting.split(separator: ",") {
            let feature = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !feature.isEmpty else { continue }
            if seen.insert(feature).inserted {
                merged.append(feature)
            }
        }

        for required in ["ssh-env", "ssh-terminfo"] {
            if seen.insert(required).inserted {
                merged.append(required)
            }
        }

        return merged.joined(separator: ",")
    }

    static func bundledShellIntegrationScript(
        named fileName: String,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> String? {
        bundledScript(
            named: fileName,
            subdirectory: "shell-integration",
            bundleResourceURL: bundleResourceURL,
            fileManager: fileManager
        )
    }

    static func bundledExecutableScript(
        named fileName: String,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> String? {
        bundledScript(
            named: fileName,
            subdirectory: "bin",
            bundleResourceURL: bundleResourceURL,
            fileManager: fileManager
        )
    }

    private static func bundledScript(
        named fileName: String,
        subdirectory: String,
        bundleResourceURL: URL?,
        fileManager: FileManager
    ) -> String? {
        guard let bundleResourceURL else { return nil }
        let url = bundleResourceURL
            .appendingPathComponent(subdirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else {
            return nil
        }
        return contents
    }

    private static func commonShellLines(
        remoteRelayPort: Int,
        bridgeHostID: String?,
        shellStateDir: String,
        shellFeatures: String,
        terminfoSource: String?
    ) -> [String] {
        let relaySocket = remoteRelayPort > 0 ? "127.0.0.1:\(remoteRelayPort)" : nil
        var lines = terminalSetupLines(terminfoSource: terminfoSource)
        lines.append(contentsOf: RemoteShellEnvironment.utf8LocaleSetupLines())
        lines.append(contentsOf: shellExportLines(shellFeatures: shellFeatures))
        lines.append("export PATH=\"$HOME/.uniconnect/bin:$PATH\"")
        lines.append("export UNICONNECT_BUNDLED_CLI_PATH=\"$HOME/.uniconnect/bin/uniconnect\"")
        lines.append("export CMUX_SHELL_INTEGRATION_DIR=\"\(shellStateDir)\"")
        if let relaySocket {
            lines.append("export CMUX_SOCKET_PATH=\(relaySocket)")
        }
        if let bridgeHostID = normalizedEnvValue(bridgeHostID),
           bridgeHostID.range(of: "^[A-Za-z0-9._:@-]{1,160}$", options: .regularExpression) != nil {
            lines.append("export UNICONNECT_BRIDGE_HOST_ID=\(shellQuote(bridgeHostID))")
        }
        // The assignment placeholders are replaced by `ssh-pty-attach` before
        // this script runs. Split the sentinel patterns so a missed replacement
        // does not export literal placeholder IDs into the remote shell.
        lines.append(contentsOf: [
            "cmux_workspace_id='__CMUX_WORKSPACE_ID__'",
            "case \"$cmux_workspace_id\" in \"\"|'__CMUX_''WORKSPACE_ID__') ;; *) export CMUX_WORKSPACE_ID=\"$cmux_workspace_id\"; export CMUX_TAB_ID=\"$cmux_workspace_id\" ;; esac",
            "cmux_surface_id='__CMUX_SURFACE_ID__'",
            "case \"$cmux_surface_id\" in \"\"|'__CMUX_''SURFACE_ID__') ;; *) export CMUX_SURFACE_ID=\"$cmux_surface_id\"; export CMUX_PANEL_ID=\"$cmux_surface_id\" ;; esac",
            "unset cmux_workspace_id cmux_surface_id",
            "hash -r >/dev/null 2>&1 || true",
            "rehash >/dev/null 2>&1 || true",
        ])
        return lines
    }

    private static func terminalSetupLines(terminfoSource: String?) -> [String] {
        var lines: [String] = [
            "cmux_term='xterm-256color'",
            "if command -v infocmp >/dev/null 2>&1 && infocmp xterm-ghostty >/dev/null 2>&1; then",
            "  cmux_term='xterm-ghostty'",
            "fi",
            "export TERM=\"$cmux_term\"",
        ]
        guard let terminfoSource else { return lines }
        let trimmedTerminfoSource = terminfoSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerminfoSource.isEmpty else { return lines }
        lines += [
            "if [ \"$cmux_term\" != 'xterm-ghostty' ]; then",
            "  (",
            "    command -v tic >/dev/null 2>&1 || exit 0",
            "    mkdir -p \"$HOME/.terminfo\" 2>/dev/null || exit 0",
            "    cat <<'CMUXTERMINFO' | tic -x - >/dev/null 2>&1",
            trimmedTerminfoSource,
            "CMUXTERMINFO",
            "  ) >/dev/null 2>&1 &",
            "fi",
        ]
        return lines
    }

    private static func shellExportLines(shellFeatures: String) -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let colorTerm = normalizedEnvValue(environment["COLORTERM"]) ?? "truecolor"
        let termProgram = normalizedEnvValue(environment["TERM_PROGRAM"]) ?? "ghostty"
        let termProgramVersion = normalizedEnvValue(environment["TERM_PROGRAM_VERSION"])
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? ""
        let trimmedShellFeatures = shellFeatures.trimmingCharacters(in: .whitespacesAndNewlines)

        var exports: [String] = [
            "export COLORTERM=\(shellQuote(colorTerm))",
            "export TERM_PROGRAM=\(shellQuote(termProgram))",
        ]
        if !termProgramVersion.isEmpty {
            exports.append("export TERM_PROGRAM_VERSION=\(shellQuote(termProgramVersion))")
        }
        if !trimmedShellFeatures.isEmpty {
            exports.append("export GHOSTTY_SHELL_FEATURES=\(shellQuote(trimmedShellFeatures))")
        }
        return exports
    }

    private static func relayWarmupLines(remoteRelayPort: Int) -> [String] {
        guard remoteRelayPort > 0 else {
            return []
        }
        return [
            "cmux_relay_cli=\"${UNICONNECT_BUNDLED_CLI_PATH:-$HOME/.uniconnect/bin/uniconnect}\"",
            "if [ ! -x \"$cmux_relay_cli\" ]; then cmux_relay_cli=\"$(command -v uniconnect 2>/dev/null || true)\"; fi",
            "cmux_relay_tty=\"${CMUX_BOOTSTRAP_TTY:-}\"",
            "if [ -z \"$cmux_relay_tty\" ]; then cmux_relay_tty=\"$(tty 2>/dev/null || true)\"; fi",
            "cmux_relay_tty=\"${cmux_relay_tty##*/}\"",
            "if [ -n \"$cmux_relay_tty\" ] && [ \"$cmux_relay_tty\" != \"not a tty\" ]; then",
            "  mkdir -p \"$HOME/.uniconnect/relay\" >/dev/null 2>&1 || true",
            "  printf '%s' \"$cmux_relay_tty\" > \"$HOME/.uniconnect/relay/\(remoteRelayPort).tty\" 2>/dev/null || true",
            "fi",
            "if [ -n \"$cmux_relay_cli\" ] && [ -n \"$CMUX_WORKSPACE_ID\" ] && [ -n \"$cmux_relay_tty\" ] && [ \"$cmux_relay_tty\" != \"not a tty\" ]; then",
            "  cmux_relay_report_tty=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"tty_name\\\":\\\"$cmux_relay_tty\\\"}\"",
            "  cmux_relay_ports_kick=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"reason\\\":\\\"command\\\"}\"",
            "  if [ -n \"$CMUX_SURFACE_ID\" ]; then",
            "    cmux_relay_report_tty=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"surface_id\\\":\\\"$CMUX_SURFACE_ID\\\",\\\"tty_name\\\":\\\"$cmux_relay_tty\\\"}\"",
            "    cmux_relay_ports_kick=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"surface_id\\\":\\\"$CMUX_SURFACE_ID\\\",\\\"reason\\\":\\\"command\\\"}\"",
            "  fi",
            "  \"$cmux_relay_cli\" rpc surface.report_tty \"$cmux_relay_report_tty\" >/dev/null 2>&1 || true",
            "  \"$cmux_relay_cli\" rpc surface.ports_kick \"$cmux_relay_ports_kick\" >/dev/null 2>&1 || true",
            "fi",
            "unset CMUX_BOOTSTRAP_TTY cmux_relay_cli cmux_relay_tty cmux_relay_report_tty cmux_relay_ports_kick",
        ]
    }

    private static func shellStateDirForRemoteRelayPort(_ remoteRelayPort: Int) -> String {
        "$HOME/.uniconnect/relay/\(max(remoteRelayPort, 0)).shell"
    }

    private static func normalizedEnvValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
