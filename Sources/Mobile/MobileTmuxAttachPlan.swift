import Foundation

/// An ephemeral, validated attachment to an existing desktop terminal's tmux session.
struct MobileTmuxAttachPlan: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let workspaceID: UUID
    let surfaceID: UUID
    /// Sensitive canonical shell text for the private PTY launcher. Never log or persist it.
    let command: String
    var geometryNonce: UUID? = nil
    let identity: Identity

    struct Identity: Equatable, Sendable {
        let tabManager: ObjectIdentifier
        let workspace: ObjectIdentifier
        let panel: ObjectIdentifier
        let surface: ObjectIdentifier
        let surfaceGeneration: UUID
        let profileIdentity: UUID?
        let target: Target
    }

    enum Target: Equatable, Sendable {
        case local(recordID: UUID, binding: UniConnectLocalTmuxBinding)
        case ssh(credentialID: UUID, revisionDigest: Data, target: UniConnectSSHEffectiveTarget, session: String)
    }

    var description: String {
        "MobileTmuxAttachPlan(workspaceID: \(workspaceID), surfaceID: \(surfaceID), command: <redacted>)"
    }

    var debugDescription: String { description }

    /// Links the existing window into an owned presentation session without restarting its panes.
    static func localCommand(binding: UniConnectLocalTmuxBinding, tmuxExecutable: String? = nil, geometryNonce: UUID? = nil) -> String {
        attachScript(
            session: binding.name, socketName: binding.socketName, tmuxExecutable: tmuxExecutable,
            geometryNonce: geometryNonce
        )
    }

    static func sshCommand(record: UniConnectSSHCredentialRecord, session: String, geometryNonce: UUID? = nil) throws -> String {
        guard !session.isEmpty, UniConnectSSH.sanitizedTmuxName(session) == session,
              let target = record.effectiveTarget,
              let validated = UniConnectSSHConnectCommandValidator().validatedCommand(record.connectCommand),
              let command = validated.sensitiveCanonicalShellCommand(
                injecting: ["-t", "-t"] + UniConnectSSH.baseClientOptions,
                pinnedTo: target,
                remoteCommand: "/bin/sh -c " + UniConnectSSH.singleQuoted(attachScript(session: session, geometryNonce: geometryNonce))
              ) else {
            throw MobileTmuxAttachError.invalidSSHCredential
        }
        return command
    }

    private static func attachScript(
        session: String,
        socketName: String? = nil,
        tmuxExecutable: String? = nil,
        geometryNonce: UUID? = nil
    ) -> String {
        let quote = UniConnectSSH.singleQuoted
        let resolveExecutable = tmuxExecutable.map { "uc_mobile_tmux=\(quote($0))" } ?? """
        uc_mobile_tmux=$(command -v tmux 2>/dev/null || :)
        if [ -z "$uc_mobile_tmux" ]; then
            for uc_mobile_candidate in /opt/homebrew/bin/tmux /usr/local/bin/tmux; do
                if [ -x "$uc_mobile_candidate" ]; then uc_mobile_tmux=$uc_mobile_candidate; break; fi
            done
        fi
        """
        let socket = socketName.map { " -L " + quote($0) } ?? ""
        let exactTarget = quote("=" + session)
        // Pane-target commands need the colon to interpret this as a session.
        let exactPaneTarget = quote("=" + session + ":")
        let missing = quote(MobileTmuxAttachError.missingTmux.localizedDescription)
        let unsupported = quote(MobileTmuxAttachError.unsupportedTmux.localizedDescription)
        let sessionMissing = quote(MobileTmuxAttachError.missingSession.localizedDescription)
        let geometryBootstrap = geometryNonce.map { nonce in
            let token = nonce.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            // Capture this client's tty now. Hook contexts may later belong to the
            // desktop client that resized the linked window; never use its tty.
            return """
            uc_mobile_tty=$(/usr/bin/tty 2>/dev/null) || exit 69
            case "$uc_mobile_tty" in /dev/tty*|/dev/pts/*) ;; *) exit 69 ;; esac
            case "$uc_mobile_tty" in *[!a-zA-Z0-9/_-]*) exit 69 ;; esac
            uc_mobile_geometry_script="(printf '\\\\036UCPTY_GEOMETRY_\(token):%s:%s:%s\\\\037' '#{window_width}' '#{window_height}' '#{status}' > '$uc_mobile_tty') 2>/dev/null || :"
            uc_mobile_geometry_hook="run-shell -b -t '=$uc_mobile_aux:' \\"$uc_mobile_geometry_script\\""
            """
        } ?? ""
        let geometryHooks = geometryNonce == nil ? "" : """
        set-hook -t "=$uc_mobile_aux:" window-resized "$uc_mobile_geometry_hook" \\; \\
        set-hook -t "=$uc_mobile_aux:" client-resized "$uc_mobile_geometry_hook" \\; \\
        set-hook -t "=$uc_mobile_aux:" after-set-option "$uc_mobile_geometry_hook" \\; \\
        """ + "\n"
        let geometryInitial = geometryNonce == nil ? "" : """
        \\; run-shell -b -t "=$uc_mobile_aux:" "$uc_mobile_geometry_script"
        """
        // tmux silently ignores unknown client flags. Both the executable and the
        // existing server must be known to support ignore-size and active-pane.
        // Released 3.2...3.7 (including 3.7c) support both; development HEAD does not
        // promise these semantics. Do not infer support from a newer version number.
        return """
        unset TMUX
        \(resolveExecutable)
        if [ -z "$uc_mobile_tmux" ] || [ ! -x "$uc_mobile_tmux" ]; then
            printf '%s\\n' \(missing) >&2
            exit 69
        fi
        uc_mobile_version=$("$uc_mobile_tmux" -V 2>/dev/null) || exit 69
        case "$uc_mobile_version" in
            'tmux 3.'[2-7]|'tmux 3.'[2-7][a-z]) ;;
            *) printf '%s\\n' \(unsupported) >&2; exit 78 ;;
        esac
        set -- -N\(socket)
        if ! "$uc_mobile_tmux" "$@" has-session -t \(exactTarget) 2>/dev/null; then
            printf '%s\\n' \(sessionMissing) >&2
            exit 66
        fi
        uc_mobile_server_version=$("$uc_mobile_tmux" "$@" display-message -p -t \(exactPaneTarget) '#{version}' 2>/dev/null) || exit 66
        case "$uc_mobile_server_version" in
            3.[2-7]|3.[2-7][a-z]) ;;
            *) printf '%s\\n' \(unsupported) >&2; exit 78 ;;
        esac
        uc_mobile_target=$("$uc_mobile_tmux" "$@" display-message -p -t \(exactPaneTarget) '#{session_name}|#{session_id}:#{window_id}.#{pane_id}' 2>/dev/null) || exit 66
        case "$uc_mobile_target" in
            \(quote(session + "|"))'$'[0-9]*:@[0-9]*.%[0-9]*) ;;
            *) exit 66 ;;
        esac
        uc_mobile_target=${uc_mobile_target#*|}
        uc_mobile_window=${uc_mobile_target%.*}
        uc_mobile_pane=${uc_mobile_target##*.}
        uc_mobile_nonce=$(/usr/bin/od -An -N16 -tx1 /dev/urandom 2>/dev/null | /usr/bin/tr -d ' \\n')
        case "$uc_mobile_nonce" in ''|*[!0-9a-f]*) exit 69 ;; esac
        [ "${#uc_mobile_nonce}" -eq 32 ] || exit 69
        uc_mobile_aux=uc-mobile-$uc_mobile_nonce
        \(geometryBootstrap)
        # A grouped new-session briefly executes the server default command.
        # Two executable arguments bypass that shell entirely. The only new
        # process is an inert, bounded placeholder replaced by the existing window.
        # One server command queue makes collision/failure stop subsequent writes;
        # destroy-unattached cleans only this auxiliary on failure or disconnect.
        exec "$uc_mobile_tmux" "$@" \\
            new-session -d -E -s "$uc_mobile_aux" /bin/sleep 60 \\; \\
            set-option -t "=$uc_mobile_aux:" destroy-unattached on \\; \\
            set-option -t "=$uc_mobile_aux:" detach-on-destroy on \\; \\
            set-option -t "=$uc_mobile_aux:" mouse on \\; \\
            \(geometryHooks)link-window -k -s "$uc_mobile_window" -t "=$uc_mobile_aux:^" \\; \\
            attach-session -E -f ignore-size,active-pane -t "=$uc_mobile_aux" \\; \\
            select-pane -t "=$uc_mobile_aux:.+" \\; \\
            select-pane -t "=$uc_mobile_aux:.$uc_mobile_pane" \(geometryInitial)
        """
    }
}
