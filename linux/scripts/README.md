# Recuperación remota de sesiones

`recovery.py` mantiene las ventanas importadas en un servidor tmux independiente
(`-L uniconnect`). El manifiesto conserva el UUID original de cada conversación y
los nombres tmux calculados por `Importer`; no se construyen nombres nuevos en el
servidor. El manifiesto privado se guarda fuera del repositorio.

Antes de arrancar Codex o Antigravity se verifica que existen su historial y su
directorio. Si otra consola posee el bloqueo nativo de esa conversación, la
ventana espera hasta que esa consola salga. No se envían señales ni instrucciones
al agente original. Una vez libre, se abre el mismo UUID sin añadir un prompt.

Formato mínimo del manifiesto:

```json
{
  "schema": "uniconnect-recovery/v1",
  "tmuxSocket": "uniconnect",
  "windows": [
    {
      "workspace": "Proyecto",
      "name": "Desarrollo",
      "tmux": "uc-desarrollo-00000000",
      "agent": "codex",
      "sessionId": "00000000-0000-0000-0000-000000000000",
      "cwd": "/ruta/original",
      "repo": "/ruta/repositorio",
      "model": "gpt-6-astra",
      "reasoningEffort": "max"
    }
  ]
}
```

Los valores del ejemplo deben sustituirse por los del importador. `model` y
`reasoningEffort` son opcionales: sin ellos se conserva la configuración del
cliente. `agent: "agy"` recupera una conversación de Antigravity con su propio
cliente; `repo` puede ser `null` si el inventario original no asigna un producto.
No se convierten conversaciones entre proveedores.

Instalación en el servidor SSH, con Codex/agy disponibles en el PATH de un shell
de login y tmux, Python 3 y systemd de usuario instalados:

```sh
install -d -m 700 "$HOME/.uniconnect/recovery" "$HOME/.config/systemd/user"
install -m 700 recovery.py "$HOME/.uniconnect/recovery/recovery.py"
install -m 600 manifest.json "$HOME/.uniconnect/recovery/manifest.json"
install -m 600 uniconnect-recovery.service "$HOME/.config/systemd/user/uniconnect-recovery.service"
python3 "$HOME/.uniconnect/recovery/recovery.py" --manifest "$HOME/.uniconnect/recovery/manifest.json" validate
systemctl --user daemon-reload
systemctl --user enable --now uniconnect-recovery.service
```

Para sobrevivir al cierre del login y arrancar tras reiniciar el servidor, el
usuario necesita `Linger=yes` (`loginctl show-user "$USER" -p Linger`). Si todavía
no está habilitado, el administrador debe habilitarlo para ese usuario.

`status` devuelve solo metadatos de procesos, ventanas y bloqueos. `validate` no
arranca sesiones. `ensure` crea las ventanas faltantes una vez; `supervise` repite
esa comprobación. Las ventanas ajenas con el mismo nombre se rechazan y se
conservan. Al reiniciar el supervisor, los procesos tmux existentes continúan.
Al salir normalmente de un cliente, la ventana ofrece Intro para volver a abrir
el mismo historial; un error del cliente se reintenta tras 30 segundos.

```sh
python3 "$HOME/.uniconnect/recovery/recovery.py" --manifest "$HOME/.uniconnect/recovery/manifest.json" status
tmux -L uniconnect attach-session -t '=NOMBRE_TMUX_DEL_MANIFIESTO'
systemctl --user stop uniconnect-recovery.service
```

Parar el servicio detiene solo el supervisor y conserva las conversaciones tmux.
Las pruebas de reinicio del host requieren una ventana operativa propia; no se
reinicia un servidor de trabajo para comprobar esta instalación.
