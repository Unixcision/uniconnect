import Foundation

/// Attaches to one durable local pane; its initial command and its tmux options run only if
/// tmux creates that session, so reattaching never redraws the server's other clients.
struct UniConnectLocalTmuxLaunchPlan: Equatable, Sendable {
    let binding: UniConnectLocalTmuxBinding
    let workingDirectory: String
    let initialCommand: String?

    /// Explicit executable injection lets behavior tests run a fixture without touching a real tmux
    /// server or the real launchd.
    func startupCommand(tmuxExecutable: String? = nil, launchctlExecutable: String = "/bin/launchctl") -> String {
        let quote = TerminalStartupShellQuoting.singleQuoted
        let missingTmux = String(
            localized: "uniconnect.localWindow.tmux.missing",
            defaultValue: "tmux no está disponible. Esta consola no es recuperable; instala tmux para conservarla al cerrar UniConnect."
        )
        let missingDirectory = String(
            localized: "uniconnect.localWindow.tmux.directoryMissing",
            defaultValue: "La carpeta guardada ya no existe. Se intentará recuperar la sesión existente sin iniciar otra IA."
        )
        let failedAttach = String(
            localized: "uniconnect.localWindow.tmux.attachFailed",
            defaultValue: "No se pudo recuperar la sesión tmux. Esta consola de recuperación no inicia ninguna IA automáticamente."
        )
        let resolveExecutable = tmuxExecutable.map { "uc_tmux=\(quote($0))" } ?? """
        uc_tmux=$(command -v tmux 2>/dev/null || :)
        if [ -z "$uc_tmux" ]; then
            for uc_candidate in /opt/homebrew/bin/tmux /usr/local/bin/tmux; do
                if [ -x "$uc_candidate" ]; then uc_tmux=$uc_candidate; break; fi
            done
        fi
        """
        let agentLabel = UniConnectLocalTmuxServerAgent.label(socketName: binding.socketName)
        let paneBody = initialCommand.map { $0 + "; exec \"${SHELL:-/bin/zsh}\" -l" }
        let paneCommand = paneBody.map { "exec \"${SHELL:-/bin/zsh}\" -ilc " + quote($0) }
            ?? "exec \"${SHELL:-/bin/zsh}\" -l"
        // A pre-existing server inherited another pane's environment. Copy only the current
        // terminal's integration/context keys into the new session; never persist their values.
        let environment = Self.paneEnvironmentKeys.map {
            "set -- \"$@\" -e \"\($0)=${\($0)-}\""
        }.joined(separator: "\n")
        let script = """
        unset TMUX
        \(resolveExecutable)
        if [ -z "$uc_tmux" ] || [ ! -x "$uc_tmux" ]; then
            printf '%s\\n' \(quote(missingTmux)) >&2
            exec "${SHELL:-/bin/zsh}" -l
        fi
        set -- -f /dev/null -L \(quote(binding.socketName))
        if cd -- \(quote(workingDirectory)); then
            if "$uc_tmux" "$@" has-session -t \(quote("=" + binding.name)) 2>/dev/null; then
                # The session already carries its options. Every set-option or set-hook
                # makes tmux redraw every client of the server (all other windows and the
                # phone), so reattaching only attaches. A session gone in between gets the
                # recovery shell below, never a second agent.
                "$uc_tmux" "$@" attach-session -t \(quote("=" + binding.name))
            else
                # With no server, launchd starts it from its agent (UniConnectLocalTmuxServerAgent):
                # a server born from this terminal would belong to UniConnect's coalition, and a
                # Force Quit of the app kills the whole coalition. Bounded deadline: launchd
                # offers no readiness signal a shell can await. Without the agent, or if it does
                # not answer in time, new-session below starts the server as before.
                if ! "$uc_tmux" "$@" -N list-sessions >/dev/null 2>&1 \
                    && \(quote(launchctlExecutable)) kickstart "gui/$(/usr/bin/id -u)/"\(quote(agentLabel)) >/dev/null 2>&1; then
                    uc_wait=50
                    until "$uc_tmux" "$@" -N list-sessions >/dev/null 2>&1 || [ "$uc_wait" -le 0 ]; do
                        /bin/sleep 0.1
                        uc_wait=$((uc_wait - 1))
                    done
                fi
                # The grid takes its history limit at creation; configure it in the same
                # tmux command queue before new-session, including on a fresh server.
                # new-session -A still attaches if another client created it meanwhile.
                set -- "$@" set-option -g history-limit 50000 ';' new-session -A -s \(quote(binding.name))
                \(environment)
                "$uc_tmux" "$@" \(quote(paneCommand)) \\; \
                    set-option -t \(quote("=" + binding.name + ":")) destroy-unattached off \\; \
                    set-option -t \(quote("=" + binding.name + ":")) status off \\; \
                    set-option -t \(quote("=" + binding.name + ":")) mouse on \\; \
                    set-option -s exit-unattached off
            fi
        else
            printf '%s\\n' \(quote(missingDirectory)) >&2
            "$uc_tmux" "$@" attach-session -t \(quote("=" + binding.name))
        fi
        uc_status=$?
        if [ "$uc_status" -eq 0 ]; then exit 0; fi
        printf '%s\\n' \(quote(failedAttach)) >&2
        exec "${SHELL:-/bin/zsh}" -l
        """
        // Ghostty's Darwin launcher already wraps this in `exec -l <command>`.
        // A second outer `exec` would be treated as an executable, not a shell builtin.
        return "/bin/sh -c " + quote(script)
    }

    private static let paneEnvironmentKeys = [
        "PATH", "SHELL", "COLORTERM", "TERM_PROGRAM", "ZDOTDIR", "GHOSTTY_RESOURCES_DIR",
        "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_PANEL_ID", "CMUX_TAB_ID", "CMUX_SOCKET_PATH",
        "UNICONNECT_SURFACE_GENERATION", "CMUX_BUNDLE_ID", "CMUX_BUNDLED_CLI_PATH",
        "CMUX_SHELL_INTEGRATION", "CMUX_SHELL_INTEGRATION_DIR", "CMUX_ZSH_ZDOTDIR",
        "CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION", "CMUX_LOAD_GHOSTTY_BASH_INTEGRATION",
        "CMUX_CLAUDE_WRAPPER_SHIM", "CMUX_CLAUDE_WRAPPER_SHIM_ROOT", "CMUX_CLAUDE_HOOKS_DISABLED",
        "CMUX_NO_GIT_WATCH", "CMUX_NO_PR_WATCH", "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE",
    ]
}
