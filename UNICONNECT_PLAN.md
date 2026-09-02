# UniConnect — Plan de ejecución (derivado de THE_BIG_GOAL.md)

Estado: `[ ]` pendiente · `[~]` en curso · `[x]` hecho y validado. Cada punto se marca solo con evidencia (build, test o prueba manual anotada).

## 1. Revisión inicial y protección del trabajo existente
- [x] 1.1 Leer CLAUDE.md / AGENTS.md del repo (build con reload.sh --tag, tests, pbxproj normalizado).
- [x] 1.2 Rama `uniconnect` creada desde `fix/sshpass-image-paste`; remotos `origin` (Unixcision/cmux) y `upstream` (manaflow-ai/cmux) intactos.
- [x] 1.3 Inventario de sistemas reutilizables: SessionPersistence (snapshot JSON + autosave 8 s), RestorableAgentSession (hooks Claude → `--resume`), resumeBinding + aprobaciones, WorkspaceRemoteConfiguration/terminalStartupCommand, ClosedItemHistory, Keychain (HMAC resume).
- [x] 1.4 Decisión: ampliar el sistema existente (campos nuevos en snapshot + módulo `Sources/UniConnect/`), no un sistema paralelo.
- [ ] 1.5 Commits por fases, sin force push ni borrado de ramas.

## 2. Renombrado completo a UniConnect
- [~] 2.1 Nombre visible (CFBundleDisplayName) → UniConnect.
- [ ] 2.2 PRODUCT_NAME / ejecutable / scheme → UniConnect (Debug "UniConnect DEV"), TEST_HOST actualizados.
- [ ] 2.3 Menús, About, Quit, status bar, ayuda: textos "cmux" → "UniConnect" (defaultValue + catálogo es/en).
- [ ] 2.4 Icono y recursos gráficos propios.
- [ ] 2.5 Scripts (reload.sh, install script, sign) adaptados al nuevo nombre de producto.
- [ ] 2.6 Bundle ID `com.cmuxterm.app` se CONSERVA (sesiones, Keychain, App Support, socket). Documentado con rollback.
- [x] 2.7 Updater oficial desactivado (SUEnableAutomaticChecks=false, SUFeedURL=about:blank; el resolver cae al appcast oficial si está vacío).
- [ ] 2.8 Carpeta local → `PROYECTOS/uniconnect` (tras validar build).
- [ ] 2.9 `gh repo rename` Unixcision/cmux → Unixcision/uniconnect; `origin` actualizado; upstream conservado; descripción/topics.
- [ ] 2.10 Verificación post-renombrado: git remotos, build, scripts.

## 3. Concepto de workspace (caja)
- [x] 3.1 Selector Local/SSH al pulsar `+` (sheet `UniConnectNewWorkspaceView`).
- [x] 3.2 Tipo persistido en snapshot (`uniConnect` en SessionWorkspaceSnapshot).
- [ ] 3.3 Tipo visible en la interfaz (badge Local/SSH en sidebar).
- [ ] 3.4 Fechas de creación / última actividad en el perfil.
- [ ] 3.5 Recuperación de cajas, ventanas, nombres, colores, orden, layout, splits, directorios y sesiones tras cierre/crash/reinicio (validación E2E).

## 4. Workspaces locales
- [x] 4.1 Alta Local: nombre + carpeta (validada) + color.
- [ ] 4.2 Carpeta desaparecida → error recuperable con selección de otra ruta.
- [x] 4.3 Restauración Claude con `claude --resume <id> --dangerously-skip-permissions` forzado siempre (AgentResumeArgv).
- [ ] 4.4 Sin diálogos repetitivos de confirmación (aprobación auto para agent-hook; investigar prompt "Bypass Permissions" de Claude).
- [ ] 4.5 Sesión inexistente → conservar ventana e informar (comprobar comportamiento actual de cmux).

## 5. Workspaces SSH
- [x] 5.1 Alta SSH: nombre + color + comando completo (ssh, sshpass, -i, -p, ProxyJump…).
- [x] 5.2 Comando guardado cifrado en bóveda (AES-GCM, clave maestra en Keychain); snapshot solo guarda `credentialId`.
- [~] 5.3 Inyección de opciones tras la palabra `ssh` (sin concatenación insegura del ID tmux: sanitizado + quoting).
- [ ] 5.4 Host keys: `StrictHostKeyChecking=accept-new` (acepta hosts nuevos, rechaza cambios). Errores de fingerprint legibles.
- [x] 5.5 Pantalla de carga: conecta, comprueba tmux, detecta gestor, instala (apt/dnf/yum/apk/pacman/zypper/brew), verifica versión.
- [ ] 5.6 Confirmación en UI antes de instalar tmux.
- [x] 5.7 Fases reales + salida sanitizada (sin porcentaje inventado).
- [~] 5.8 Errores humanizados: inaccesible, timeout, auth, sudo, gestor incompatible, sshpass ausente. Retry / Editar conexión / Cancelar.

## 6. Pantalla vacía y creación de ventanas SSH
- [x] 6.1 Caja SSH nace sin ventanas reales (placeholder oculto) y muestra página explicativa a pantalla completa.
- [x] 6.2 CTA "Crear ventana" con nombre visible + ID tmux propuesto (`uc-<slug>-<4hex>`), editable.
- [x] 6.3 Validación/sanitizado del ID (letras, dígitos, `_`, `-`, máx 40).
- [ ] 6.4 Detección de ID duplicado dentro de la caja (pedir confirmación).
- [x] 6.5 Cada ventana ejecuta `tmux new-session -A -D -s <id>` vía ssh -t con lanzador auto-borrable.
- [x] 6.6 Restauración: cada ventana reengancha al mismo ID (startup command prioritario en createPanel).
- [ ] 6.7 Estados Connecting/Connected/Retrying/Failed por ventana y retry individual.
- [ ] 6.8 Reconexiones escalonadas al restaurar muchas cajas.

## 7. Cerrar, archivar, reabrir y eliminar
- [x] 7.1 Cerrar ventana/caja no ejecuta `tmux kill-*` (solo cierra el cliente ssh; tmux se desengancha).
- [x] 7.2 Cerradas: reutiliza ClosedItemHistory (snapshot con ID tmux/perfil) + menú "Cerradas…" con Reabrir / Eliminar definitivamente (confirmado).
- [ ] 7.3 Mostrar tipo, servidor/carpeta y última actividad en Cerradas.
- [ ] 7.4 Acción separada y explícita "Terminar sesión tmux remota".

## 8. Persistencia automática y recuperación
- [x] 8.1 Autosave existente (8 s, atómico, sin escribir si no cambia) + guardado tras desbloquear y tras cambios UniConnect.
- [x] 8.2 Esquema versionado (documento v1) y campos opcionales compatibles hacia atrás en el snapshot de cmux.
- [ ] 8.3 Validación antes de reemplazar último estado válido / recuperación ante fichero corrupto (revisar SessionPersistence).
- [x] 8.4 "Persistir ahora" (⌘⌥S): snapshot completo + backup cifrado con historial (30 copias).
- [ ] 8.5 Confirmación indica cuándo y dónde, sin secretos (revisar texto).

## 9. Exportación, importación y configuración inicial
- [x] 9.1 Exportar: contenedor JSON versionado (`uniconnect-export` v1) con meta legible + payload AES-256-GCM (PBKDF2-SHA256 600k, salt/nonce únicos).
- [x] 9.2 Importar: Touch ID → validar → (contraseña) → vista previa sin secretos → selección de cajas; duplicados por nombre desmarcados.
- [ ] 9.3 Snapshot de seguridad antes de importar (para deshacer).
- [x] 9.4 Plantilla inicial (menú "Guardar plantilla inicial…") con cajas, tipo, color, carpeta/conexión, ventanas, IDs tmux.
- [ ] 9.5 Semilla real de Dani: localhost + SSH notbetting-prepro (`ssh -i …/notbetting-prepro-keys.pem root@15.217.153.205`) con ventanas tmux (pendiente lista de nombres).

## 10. Seguridad y gestión de secretos
- [x] 10.1 Secretos nunca en snapshot/logs: comando SSH solo en bóveda cifrada; clave maestra en Keychain (fallback fichero 0600).
- [ ] 10.2 Redacción en UI (`••••••••`) al mostrar comandos; revelar exige Touch ID.
- [x] 10.3 Cifrado autenticado con CryptoKit AES-GCM; AAD con nombre de formato; errores sin filtrar detalle.
- [ ] 10.4 Modelo de amenaza y limitaciones documentados.
- [ ] 10.5 Migración de secretos heredados (cmux no guarda comandos ssh en claro; comprobar `resumeBinding` process-detected con sshpass).

## 11. Touch ID, apertura y bloqueo
- [x] 11.1 Gate al arrancar (LocalAuthentication, ventana a nivel screenSaver en todas las pantallas).
- [x] 11.2 Bloquear (⌘⌃L) sin matar procesos ni tmux.
- [x] 11.3 Política sin Touch ID / no configurado / lockout: contraseña del Mac vía LAContext, avisada en pantalla, sin bypass silencioso.
- [ ] 11.4 Timeout de bloqueo automático configurable por inactividad.
- [ ] 11.5 Ocultar contenido en previews/capturas cuando sea viable.
- [ ] 11.6 Antes de exportar/revelar: autenticación reciente.

## 12. Interfaz y experiencia
- [ ] 12.1 Badge Local/SSH y estado de conexión por caja.
- [ ] 12.2 Indicador ventana Claude vs tmux.
- [ ] 12.3 "Último guardado" visible.
- [ ] 12.4 Textos de estados vacíos, loaders y errores cuidados.

## 13. README profesional
- [ ] 13.1 README.md en inglés con las 25 secciones.
- [ ] 13.2 Logo/wordmark + hero.
- [ ] 13.3 Capturas reales sanitizadas: selector Local/SSH, estado vacío SSH, ventanas tmux, bloqueo/exportación.
- [ ] 13.4 GIF optimizado del flujo principal.
- [ ] 13.5 Diagrama Mermaid (UniConnect, persistencia, Claude resume, SSH, tmux, Keychain, backups).
- [ ] 13.6 Badges reales; comprobación de enlaces, anchors e imágenes; sin datos privados.
- [ ] 13.7 Descripción/topics del repo con `gh`.

## 14. Pruebas
- [ ] 14.1 Tests unitarios: cripto (roundtrip, contraseña mala, manipulación, nonces/salts únicos), IDs tmux (válidos/inválidos/inyección), inyección de opciones ssh, documento (validación/versión), AgentResumeArgv con flag forzado.
- [ ] 14.2 Tests de snapshot: campos uniConnect sobreviven a encode/decode y a snapshots antiguos.
- [ ] 14.3 Suite existente del repo sin regresiones.
- [ ] 14.4 Comprobación manual Touch ID en hardware.

## 15. Validación E2E en build real
- [ ] 15.1 Arranque + Touch ID.
- [ ] 15.2 Caja Local con ventanas y Claude (IDs registrados).
- [ ] 15.3 Caja SSH: conexión, tmux detectado/instalado, estado vacío, varias ventanas.
- [ ] 15.4 Cerrar/reabrir desde Cerradas.
- [ ] 15.5 Persistir ahora + exportar.
- [ ] 15.6 Bloquear/desbloquear.
- [ ] 15.7 Cierre completo → tmux vivos → reapertura con recuperación exacta; Claude reanudado.
- [ ] 15.8 Crash forzado (kill -9) → recuperación.
- [ ] 15.9 Importar backup; contraseña mala y fichero manipulado rechazados.
- [ ] 15.10 Inspección de logs/snapshots/export/git en busca de secretos.

## 16. Criterios de aceptación
- [ ] Revisión final punto por punto contra THE_BIG_GOAL.md §16.

## 17. Entrega final
- [ ] Informe con resumen, rutas, URL, commits, migraciones, pruebas, evidencias, riesgos e instrucciones de semilla.
