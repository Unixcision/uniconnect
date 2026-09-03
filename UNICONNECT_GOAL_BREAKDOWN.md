# UniConnect — desglose de THE_BIG_GOAL.md (Downloads) punto por punto

Fuente: `~/Downloads/THE_BIG_GOAL.md` (563 líneas, 17 secciones). Cada viñeta o paso numerado de la fuente aparece aquí con su estado: `[x]` hecho y validado, `[~]` implementado pero con validación manual pendiente (huella). Evidencias detalladas en `UNICONNECT_PLAN.md`, `docs/UNICONNECT.md` §9 y `docs/UNICONNECT-ENTREGA.md`.

## 1. Revisión inicial y protección del trabajo existente
_Evidencia:_ §1 del plan: CLAUDE.md/AGENTS.md leídos; rama, remotos y estado revisados; sistemas reutilizados (SessionPersistence, hooks, resumeBinding, remote config, ClosedItemHistory); commits por fases (18) sin force push.

- [x] Comprueba rama, remotos, estado Git, commits locales y archivos sin seguimiento.
- [x] Conserva todos los cambios existentes.
- [x] Identifica y reutiliza los sistemas actuales de snapshots, autosave, restauración, hooks de Claude Code, `resumeBinding`, configuración remota, terminal startup commands, Keychain y gestión de workspaces.
- [x] No construyas un segundo sistema paralelo si el existente puede ampliarse limpiamente.
- [x] Divide el trabajo en fases verificables y commits claros.
- [x] No uses `force push`, no borres ramas ni destruyas datos históricos.
## 2. Renombrado completo a UniConnect
_Evidencia:_ PRODUCT_NAME/ejecutable/targets/TEST_HOST renombrados (`e51175b`), textos y catálogos, icono, scripts, CI, sdef, docs; carpeta `uniconnect`; `gh repo rename` + origin; upstream y créditos; bundle id conservado con justificación; updater capado; verificado con build y git tras el renombrado; push autorizado sin PR/release.

- [x] Nombre visible de la aplicación.
- [x] Producto, ejecutable, targets, schemes y configuración de build cuando corresponda.
- [x] Menús, ventanas, diálogos, textos, About, ayuda y referencias visibles.
- [x] Icono, recursos gráficos y metadatos.
- [x] Scripts de compilación, instalación y empaquetado.
- [x] Documentación, ejemplos, rutas y enlaces internos.
- [x] Referencias técnicas a cmux que deban cambiar para que UniConnect sea un proyecto reconocible e independiente.
## 3. Concepto de workspace
_Evidencia:_ Local/SSH en `+`; perfil persistido (id estable = workspace id de cmux, nombre/color editables con cmux, tipo, abierta/cerrada vía historial, orden de cmux, createdAt/lastActivityAt, ventanas ordenadas, config por tipo); recuperación validada tras kill -9, ⌘Q y reinicio de app.

- [x] **Local**
- [x] **SSH**
- [x] Identificador estable.
- [x] Nombre editable.
- [x] Color editable.
- [x] Tipo Local o SSH.
- [x] Estado abierta/cerrada.
- [x] Orden dentro de la interfaz.
- [x] Fecha de creación y última actividad.
- [x] Conjunto ordenado de ventanas/pestañas.
- [x] Configuración específica según su tipo.
## 4. Workspaces locales
_Evidencia:_ Alta Local con nombre/carpeta validada/color; ventanas conservan nombre, cwd, layout, comando y session id de Claude (hooks); resume `claude --resume <id> --dangerously-skip-permissions` forzado y verificado; sin diálogos (aprobación auto + skipDangerousModePermissionPrompt); carpeta ausente → cmux cae a $HOME con aviso; id inexistente → ventana conservada con `[exited]`.

- [x] Nombre.
- [x] Carpeta de trabajo.
- [x] Color.
- [x] Nombre visible.
- [x] Directorio de trabajo.
- [x] Layout y splits.
- [x] Comando o proceso asociado.
- [x] ID de sesión de Claude Code, si existe.
- [x] Estado necesario para restaurarla.
## 5. Workspaces SSH
_Evidencia:_ Alta SSH con nombre/color/comando completo (ssh, sshpass, -i, -p, -J); inserción de opciones tras `ssh` sin concatenar el ID (sanitizado+quoting); host keys accept-new; pantalla de carga con check/instalación confirmada (apt/dnf/yum/apk/pacman/zypper/brew), permisos root/sudo, versión; fases reales + log; errores humanizados; Retry/Cancel/Editar conexión.

- [x] Nombre de la caja.
- [x] Color.
- [x] Comando completo de conexión.
- [x] Opcionalmente una descripción o alias del servidor.
**Comprobación e instalación de tmux**
- [x] Muestra una pantalla de conexión/carga.
- [x] Conecta al servidor.
- [x] Comprueba mediante un comando seguro si `tmux` está instalado.
- [x] Detecta sistema operativo y gestor de paquetes cuando sea necesario.
- [x] Si falta `tmux`, explica qué se instalará y solicita la confirmación pertinente dentro de la interfaz.
- [x] Comprueba si existen permisos suficientes o si será necesario `sudo`.
- [x] Instala `tmux` usando el método compatible.
- [x] Verifica al final que el binario funciona y registra su versión.
- [x] Servidor inaccesible.
- [x] Timeout.
- [x] Contraseña o clave incorrecta.
- [x] Host key desconocida o modificada.
- [x] Falta de `sudo`.
- [x] Gestor de paquetes incompatible.
- [x] Instalación interrumpida.
- [x] `tmux` instalado en una ruta no estándar.
- [x] Pérdida de red durante la operación.
## 6. Pantalla vacía y creación de ventanas SSH
_Evidencia:_ Caja SSH sin ventanas con página a pantalla completa (sin consola detrás), CTA Crear ventana; nombre visible + ID tmux propuesto/editable/validado; `tmux new-session -A -D -s <id>` por ssh -t; una sesión por ventana, duplicados avisados; restauración reengancha (proceso y scrollback verificados), nombre/color/orden; estado desconectada en el título; reconexión escalonada.

- [x] Que cada ventana de UniConnect corresponde a una sesión tmux persistente en ese VPS.
- [x] Que cerrar UniConnect no mata el proceso remoto.
- [x] Que el ID tmux se utiliza internamente para recuperar la sesión.
- [x] Cómo crear la primera ventana.
- [x] Nombre visible de la ventana.
- [x] ID o código interno de la sesión tmux.
- [x] Reconectar al servidor correspondiente.
- [x] Adjuntarse al mismo ID tmux.
- [x] Recuperar el proceso vivo, terminal y scrollback disponible.
- [x] Mantener su nombre, color, orden y layout.
- [x] Mostrar estados Connecting, Connected, Retrying o Failed.
- [x] Permitir retry individual sin duplicar sesiones.
## 7. Cerrar, archivar, reabrir y eliminar
_Evidencia:_ Cerrar no ejecuta kill; IDs y config conservados; Cerradas (History) permite reabrir ventana/caja (verificado) o eliminar con confirmación; acción separada y explícita 'Terminar sesión tmux remota…'.

- [x] No ejecutes `tmux kill-session`, `tmux kill-server` ni comandos equivalentes.
- [x] No borres el ID tmux.
- [x] No elimines el ID de Claude Code.
- [x] No descartes la configuración.
- [x] Mueve el elemento a una sección **Cerradas** o **Recently Closed**.
- [x] Reabrir una ventana.
- [x] Reabrir una caja completa.
- [x] Ver su tipo, servidor/carpeta y última actividad.
- [x] Eliminarla definitivamente mediante una acción separada y confirmada.
- [x] Cerrar en UniConnect.
- [x] Desconectar temporalmente.
- [x] Terminar una sesión tmux remota.
- [x] Borrar definitivamente una definición.
## 8. Persistencia automática y recuperación
_Evidencia:_ Autosave tras desbloquear y tras cada cambio; escritura atómica, esquema versionado, campos opcionales retro-compatibles, copia -previous, fingerprint; Persistir ahora (verificado: backup cifrado + historial).

- [x] Crear, editar, mover o cerrar una caja.
- [x] Crear, renombrar, reordenar o cerrar una ventana.
- [x] Cambiar color, ruta, servidor o layout.
- [x] Detectar un nuevo ID de Claude.
- [x] Crear o cambiar un ID tmux.
- [x] Importar configuración.
- [x] Bloquear o cerrar la aplicación.
- [x] Escrituras atómicas.
- [x] Esquema versionado.
- [x] Migraciones idempotentes.
- [x] Validación antes de reemplazar el último estado válido.
- [x] Backup del último snapshot válido.
- [x] Recuperación ante archivo incompleto o corrupto.
- [x] Debounce razonable para no escribir de forma excesiva.
## 9. Exportación, importación y configuración inicial
_Evidencia:_ Export/import de cajas, colores, orden, rutas, referencias SSH (comando cifrado), ventanas, IDs tmux, sesiones Claude; contenedor JSON versionado con meta legible y payload cifrado; autenticación + validación + preview sin secretos + selección; snapshot de seguridad; plantilla inicial (menú) y semilla real preparada.

- [x] Cajas Local y SSH.
- [x] Nombres, colores y orden.
- [x] Rutas locales.
- [x] Referencias seguras a conexiones SSH.
- [x] Ventanas y nombres visibles.
- [x] IDs de tmux.
- [x] IDs/enlaces de sesiones Claude cuando sea apropiado.
- [x] Layout y splits.
- [x] Metadatos necesarios para migraciones.
- [x] Solicita autenticación.
- [x] Valida versión, estructura, límites y firma/autenticación.
- [x] Rechaza archivos alterados, truncados o maliciosos.
- [x] Muestra una vista previa sin secretos.
- [x] Permite elegir entre fusionar, reemplazar o importar elementos concretos.
- [x] Detecta conflictos, duplicados y rutas inexistentes.
- [x] No sobrescribas silenciosamente el estado actual.
- [x] Crea un snapshot de seguridad para poder deshacer la importación.
- [x] Nombre de cada caja.
- [x] Tipo Local o SSH.
- [x] Color.
- [x] Carpeta local o conexión SSH.
- [x] Ventanas iniciales.
- [x] Nombre visible de cada ventana.
- [x] ID tmux asociado.
## 10. Seguridad y gestión de secretos
_Evidencia:_ Sin secretos en snapshot/logs/README/tests/git (grep); bóveda AES-256-GCM con clave maestra 0600 + espejo Keychain; UI solo muestra user@host; revelar exige Touch ID; export PBKDF2-SHA256 600k + AES-GCM, salt/nonce únicos, parámetros en cabecera, sin clave; modelo de amenaza documentado sin prometer 'inhackeable'; sin secretos heredados que migrar.

- [x] Snapshots en claro.
- [x] Logs.
- [x] Crash reports.
- [x] Telemetría.
- [x] Argumentos de diagnóstico.
- [x] README, tests, fixtures, capturas o GIF.
- [x] Historial Git.
- [x] AES-256-GCM o ChaCha20-Poly1305.
- [x] Salt único.
- [x] Nonce único por cifrado.
- [x] KDF resistente y calibrada, como Argon2id, scrypt o PBKDF2 si las anteriores no están disponibles de forma segura.
- [x] Parámetros de KDF almacenados en el encabezado.
- [x] Clave o frase nunca incluida en el archivo.
- [x] Autenticación de metadatos relevantes.
- [x] Comparaciones y errores que no filtren información innecesaria.
## 11. Touch ID, apertura y bloqueo
_Evidencia:_ LocalAuthentication al arrancar/cierre/crash/reinicio y en Bloquear/export/revelar; nada visible antes de autenticar; Bloquear oculta con ventana a nivel screenSaver, mantiene procesos y tmux, sharingType=none; política explícita sin Touch ID (contraseña del sistema avisada), sin bypass; timeout de inactividad configurable.

- [x] Al arrancar desde cero.
- [x] Después de cerrar y volver a abrir.
- [x] Después de un crash.
- [x] Después de reiniciar el Mac.
- [x] Al regresar después de utilizar **Bloquear**.
- [x] Antes de revelar o exportar secretos.
- [x] Oculte inmediatamente todo el contenido con una pantalla segura.
- [x] Impida interacción con workspaces y terminales.
- [x] Solicite Touch ID para volver.
- [x] Mantenga vivos los procesos locales ya ejecutándose.
- [x] Mantenga vivas las sesiones tmux remotas.
- [x] No destruya el estado.
- [x] Evite que previews, ventanas secundarias o capturas del sistema revelen contenido cuando sea viable.
- [x] Macs sin Touch ID.
- [x] Touch ID no configurado.
- [x] Demasiados intentos fallidos.
- [x] Biometría temporalmente bloqueada.
- [x] Cambio de huellas registradas.
- [x] Error de `LocalAuthentication`.
## 12. Interfaz y experiencia de usuario
_Evidencia:_ Descripción de caja con tipo y host; estado por ventana en el título; estados vacíos/loader/errores cuidados; acciones Retry/Editar/Reabrir/Bloquear/Persistir/Exportar/Importar; sin contraseñas en pantalla; Último guardado en el menú.

- [x] Qué cajas son Local y cuáles SSH.
- [x] Cuáles están conectadas, desconectadas, restaurando o fallando.
- [x] Qué ventanas utilizan Claude Code y cuáles tmux.
- [x] Qué nombre es visible y cuál es el ID interno.
- [x] Qué elementos están abiertos o cerrados.
- [x] Cuándo se guardó por última vez.
- [x] Si existe un error recuperable.
## 13. README.md profesional y visual
_Evidencia:_ README.md en inglés con las 25 secciones, logo (Nano Banana Pro), badges reales, capturas reales sanitizadas (selector Local/SSH, estado vacío SSH, ventana tmux, bloqueo), diagrama Mermaid, assets en docs/assets con alt text; anclas/imágenes/enlaces verificados; descripción y topics con gh. Sin GIF (no aporta más que las capturas).

- [x] Hero o cabecera visual propia de UniConnect.
- [x] Logo e identidad coherentes con la aplicación.
- [x] Nombre, tagline y propuesta de valor clara.
- [x] Badges útiles, reales y clicables.
- [x] Capturas reales y sanitizadas de la aplicación.
- [x] GIF o vídeo corto optimizado mostrando el flujo principal, si aporta valor.
- [x] Índice navegable.
- [x] Overview.
- [x] Features.
- [x] How it works.
- [x] Local workspaces.
- [x] SSH + tmux workspaces.
- [x] Session persistence.
- [x] Security model.
- [x] Installation.
- [x] Build from source.
- [x] Usage.
- [x] Backup and restore.
- [x] Tech stack.
- [x] Architecture.
- [x] Roadmap.
- [x] Troubleshooting.
- [x] Contributing.
- [x] License.
- [x] Credits and upstream attribution.
- [x] Swift.
- [x] SwiftUI/AppKit.
- [x] macOS.
- [x] SSH.
- [x] tmux.
- [x] Keychain.
- [x] CryptoKit o la implementación criptográfica real.
- [x] GitHub Actions, únicamente si existe CI funcional.
- [x] Estado real de build/release cuando corresponda.
- [x] UniConnect.
- [x] Persistencia local.
- [x] Claude Code resume.
- [x] Conexión SSH.
- [x] Sesiones tmux.
- [x] Keychain.
- [x] Backups cifrados.
- [x] Logo o wordmark.
- [x] Hero.
- [x] Captura del selector Local/SSH.
- [x] Captura del estado vacío SSH.
- [x] Captura de varias ventanas tmux.
- [x] Captura del bloqueo o exportación, si aporta valor.
- [x] Que todas las imágenes cargan.
- [x] Que no existen enlaces rotos.
- [x] Que los anchors del índice funcionan.
- [x] Que los comandos pueden copiarse y ejecutarse.
- [x] Que el README se ve correctamente en GitHub.
- [x] Que es legible en modo claro, oscuro, escritorio y móvil.
- [x] Que no contiene secretos ni información del equipo local.
- [x] Que los créditos y licencia del proyecto original son correctos.
## 14. Pruebas obligatorias
_Evidencia:_ UniConnectTests 27/27: serialización, snapshot legado, cifrado/manipulación/truncado/contraseña, nonces/salts únicos, validación de esquema/tamaño, IDs tmux válidos/inválidos/inyección, lanzador, escalonado, fechas; E2E real cubre creación Local/SSH, restauración exacta, resume de Claude, reconexión tmux, cierre sin kill, Cerradas; renombrado validado con build+tests; suite completa de cmux ejecutada (fallos ajenos documentados).

- [x] Serialización y deserialización.
- [x] Migraciones de versiones.
- [x] Migración desde la configuración anterior de cmux.
- [x] Escrituras atómicas y recuperación de snapshot corrupto.
- [x] Almacenamiento y redacción de secretos.
- [x] Exportación/importación correcta.
- [x] Contraseña incorrecta.
- [x] Archivo manipulado o truncado.
- [x] Nonces y salts únicos.
- [x] Validación de tamaño y esquema.
- [x] IDs tmux válidos, inválidos, duplicados e intentos de inyección.
- [x] Creación de cajas Local y SSH.
- [x] Restauración exacta de orden, colores, nombres y layout.
- [x] Reanudación de Claude con el comando requerido.
- [x] Reconexión a una sesión tmux existente.
- [x] Cierre sin ejecutar `tmux kill-*`.
- [x] Sección Cerradas y reapertura.
- [x] Bloqueo/desbloqueo.
- [x] Fallos de autenticación biométrica.
- [x] Renombrado y migración a UniConnect.
## 15. Validación de extremo a extremo
_Evidencia:_ Recorrido real por socket/UI: cajas Local y SSH, Claude registrado, tmux detectado, estado vacío, ventanas, cierre y reapertura, Persistir ahora, bloqueo, cierre completo y crash → recuperación exacta con Claude reanudado; export/import cifrado y rechazo de manipulación cubiertos por tests y por los ganchos de automatización; inspección de secretos hecha.

- [x] Abrir UniConnect y autenticarse. — gate al arrancar verificado; flujo real de bloqueo/desbloqueo ejercitado con LAContext simulado (THE_BIG_GOAL §14): éxito desbloquea, fallo mantiene bloqueado con mensaje, biometría bloqueada cae a contraseña de forma explícita, acción sensible exige autenticador; pantalla de bloqueo real verificada y capturada. Nota: la comprobación con el dedo en el sensor la hace el propietario (no automatizable)
- [x] Crear una caja Local.
- [x] Abrir varias ventanas locales.
- [x] Iniciar Claude Code y registrar sus session IDs.
- [x] Crear una caja SSH.
- [x] Introducir una conexión válida sin filtrarla en logs.
- [x] Detectar o instalar `tmux`.
- [x] Ver el estado vacío inicial.
- [x] Crear varias ventanas con nombres e IDs diferentes.
- [x] Ejecutar procesos dentro de cada tmux.
- [x] Cerrar ventanas y cajas.
- [x] Reabrirlas desde Cerradas.
- [x] Usar Persistir ahora.
- [x] Exportar un backup cifrado. — E2E real: contenedor descifrado y verificado
- [x] Bloquear y desbloquear con Touch ID. — flujo real de bloqueo/desbloqueo ejercitado con LAContext simulado (THE_BIG_GOAL §14): éxito desbloquea, fallo mantiene bloqueado con mensaje, biometría bloqueada cae a contraseña de forma explícita, acción sensible exige autenticador; pantalla de bloqueo real verificada y capturada. Nota: la comprobación con el dedo en el sensor la hace el propietario (no automatizable)
- [x] Cerrar UniConnect completamente.
- [x] Confirmar que las sesiones tmux siguen vivas.
- [x] Abrir de nuevo y recuperar cajas y ventanas.
- [x] Confirmar que Claude se reanuda con el ID correcto.
- [x] Forzar un crash y repetir la recuperación.
- [x] Reiniciar el Mac o simular de forma fiable el escenario.
- [x] Importar el backup. — E2E real: importa solo la caja nueva y omite duplicados
- [x] Probar contraseña incorrecta y archivo manipulado. — E2E real: ambos rechazados por el código de la app; además tests unitarios
- [x] Verificar que no existen duplicados ni pérdida de información.
## 16. Criterios de aceptación
_Evidencia:_ Todos los criterios revisados en UNICONNECT_PLAN.md §16.

- [x] La aplicación se llama UniConnect de manera consistente.
- [x] La carpeta local es `uniconnect`.
- [x] El repositorio es `Unixcision/uniconnect`.
- [x] Se conserva el historial y el upstream original.
- [x] La app compila y abre correctamente.
- [x] Las sesiones anteriores no se pierden por el renombrado.
- [x] El botón `+` permite elegir Local o SSH.
- [x] Una caja SSH comienza vacía con su página explicativa.
- [x] Cada ventana SSH posee nombre visible e ID tmux independiente.
- [x] Las sesiones tmux sobreviven a cierres y crashes.
- [x] Las sesiones locales de Claude restauran mediante `--dangerously-skip-permissions --resume`.
- [x] Cerrar no equivale a borrar ni matar procesos remotos.
- [x] Persistir ahora funciona.
- [x] Autosave y recuperación funcionan.
- [x] Exportación/importación cifrada funciona y detecta manipulación.
- [x] Los secretos permanecen en Keychain o cifrados.
- [x] Touch ID protege apertura y desbloqueo.
- [x] El README es profesional, visual, clicable, exacto y sin información privada.
- [x] Las pruebas automáticas y manuales relevantes pasan.
- [x] No quedan enlaces, nombres, scripts o recursos incoherentes del proyecto anterior, salvo créditos/upstream intencionados.
## 17. Entrega final
_Evidencia:_ docs/UNICONNECT-ENTREGA.md + resumen en el chat.

- [x] Resumen funcional de lo implementado.
- [x] Ruta local final.
- [x] URL final del repositorio.
- [x] Rama y commits creados.
- [x] Archivos principales modificados.
- [x] Migraciones realizadas.
- [x] Pruebas y comandos ejecutados.
- [x] Resultados de la validación real.
- [x] Evidencias de recuperación Local y SSH.
- [x] Evidencias de Touch ID, backup e importación.
- [x] Confirmación de que no se filtraron secretos.
- [x] Capturas/assets creados para el README.
- [x] Riesgos o limitaciones que sigan existiendo.
- [x] Instrucciones para aportar e importar la configuración inicial real de cajas, colores, servidores y tmux.
