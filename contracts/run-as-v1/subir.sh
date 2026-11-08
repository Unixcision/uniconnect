# run-as.v1: subir de usuario dentro del panel tmux. Linux y el Mac ejecutan ESTE mismo texto.
#
#   sh -c "$(cat subir.sh)" uc-subir <sudo|su> <usuario> <id-ventana> <orden>
#
# <orden> es lo que el panel ejecutaría sin subir (cd, IS_SANDBOX, la IA y el shell final).
# Se ejecuta como <usuario> solo si `id -un` lo confirma; si no, el panel sigue con el usuario de
# conexión, sin IA. La contraseña NUNCA llega por argv ni por el entorno:
# - sudo la pide a un askpass que lee el fichero 0600 <dir>/<id>.secret, que el host deja justo
#   antes de crear la sesión, y lo borra al leerlo (o a los 30 s si sudo no la pide, con el askpass);
# - su la lee del PTY: el host la pega con tmux load-buffer/paste-buffer -d cuando este diario
#   acaba en «Password: » y su está en primer plano.
# Diario (sin secretos): <dir>/<id>.log, con <dir> = $HOME/.local/state/uniconnect/runas (0700).
# Marcas: UC_RUNAS_OK <usuario> · UC_RUNAS_WRONG <usuario> · UC_RUNAS_END <estado>, más los
# mensajes de sudo/su en LC_ALL=C (de ahí sale la causa de run_as_failed).
uc_method=$1 uc_user=$2 uc_id=$3 uc_inner=$4
uc_shell() { exec "${SHELL:-/bin/sh}" -l; }
case $uc_user in ''|-*|*[!A-Za-z0-9_.-]*) printf '[UniConnect] Usuario no válido para subir\n' >&2; uc_shell;; esac
case $uc_id in ''|*[!A-Za-z0-9-]*) printf '[UniConnect] Ventana no válida para subir\n' >&2; uc_shell;; esac
uc_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
uc_dir=$HOME/.local/state/uniconnect/runas
umask 077
mkdir -p "$uc_dir" && chmod 700 "$uc_dir" || uc_shell
uc_log=$uc_dir/$uc_id.log
: > "$uc_log"
# LC_ALL=C solo para los mensajes de sudo/su; la ventana recupera el que tenía.
if [ "${LC_ALL+x}" = x ]; then uc_locale="export LC_ALL=$(uc_q "$LC_ALL"); "; else uc_locale='unset LC_ALL; '; fi
uc_check="if [ \"\$(id -un)\" != '$uc_user' ]; then printf 'UC_RUNAS_WRONG %s\\n' \"\$(id -un)\" >&2; exit 97; fi; printf 'UC_RUNAS_OK %s\\n' \"\$(id -un)\" >&2; exec 2>&1; $uc_locale"
case $uc_method in
  sudo)
    uc_secret=$uc_dir/$uc_id.secret uc_askpass=$uc_dir/$uc_id.askpass
    printf '#!/bin/sh\ncat %s 2>/dev/null\nrm -f %s\n' "$(uc_q "$uc_secret")" "$(uc_q "$uc_secret")" > "$uc_askpass"
    chmod 700 "$uc_askpass"
    ( sleep 30; rm -f "$uc_secret" "$uc_askpass" ) </dev/null >/dev/null 2>&1 &
    if [ "$uc_user" = root ]; then set -- -i; else set -- -i -u "$uc_user"; fi
    LC_ALL=C SUDO_ASKPASS=$uc_askpass sudo -A "$@" -- /bin/sh -c "$uc_check$uc_inner" 2>>"$uc_log"
    uc_status=$?
    rm -f "$uc_secret" "$uc_askpass"
    ;;
  su)
    # `su -c` abre una sesión nueva SIN terminal de control (la IA no tendría TTY ni control de
    # trabajos); --session-command la mantiene en la del panel. Sin él, -c.
    uc_su_command=-c
    su --help 2>&1 | grep -q -- --session-command && uc_su_command=--session-command
    LC_ALL=C su - "$uc_user" "$uc_su_command" "$uc_check$uc_inner" 2>>"$uc_log"
    uc_status=$?
    ;;
  *)
    printf 'unknown method\n' >> "$uc_log"
    uc_status=2
    ;;
esac
printf 'UC_RUNAS_END %s\n' "$uc_status" >> "$uc_log"
if ! grep -q '^UC_RUNAS_OK ' "$uc_log"; then
  printf '\n[UniConnect] No se pudo ejecutar como %s. Sigues con tu usuario y sin IA.\n' "$uc_user"
fi
uc_shell
