# UniConnect — informe de entrega

Fecha de preparación: 2026-09-03

Rama: `uniconnect`

Estado: **candidato en validación; todavía no instalado en `/Applications`**

Este documento refleja únicamente el árbol actual. Los resultados finales de Debug,
Release, pruebas, firma, push e instalación se añadirán cuando hayan sido ejecutados;
no se consideran aprobados por una validación histórica.

## Resultado funcional del candidato

- Producto, proceso y aplicación: **UniConnect**; bundle ID
  `com.unixcision.uniconnect`. El comando de compatibilidad de terminal continúa
  llamándose `cmux` por decisión de arquitectura.
- Estado normal aislado de cmux. La única lectura de datos de cmux pertenece a la
  acción explícita y de solo lectura **Migrar desde cmux**.
- Cajas locales y SSH con ventanas persistentes, nombres, orden, color, directorio,
  agente y sesión. Los cambios observables disparan persistencia automática.
- Ventanas locales para Terminal, Claude, Codex, Agy, Grok y comandos personalizados.
  Claude y Agy usan su modo de confianza configurado; Codex usa `--yolo`. Salir del
  agente conserva la ventana como shell y la conversación puede reanudarse o
  sustituirse por otro agente.
- Restauración y reconexión SSH solo se adjuntan a un tmux que ya existe. La creación
  de una ventana nueva es la única ruta autorizada para crear una sesión tmux. Nunca
  se usa una opción que expulse a otro cliente.
- Reconexión inmediata de una ventana colgada por cambio de red y acción global para
  las ventanas caídas, conservando caja, posición, credencial y tmux.
- Importación directa de `CONNECT.md` con análisis previo, selección, reconciliación
  determinista, checkpoint cifrado, diario transaccional y rollback verificable.
- Bóveda para material de conexión SSH; snapshots, previews, diarios y logs quedan
  sanitizados. En Release, la clave maestra estable debe residir en Keychain.
- Backups automáticos cada seis horas, siete días de retención y máximo de 28 puntos
  programados, además de checkpoints explícitos antes de restaurar o importar.
- Transferencia de imágenes gobernada por el tipo de caja. En SSH falla de forma
  cerrada si falta un perfil válido, muestra porcentaje real y permite cancelar.
- Puente namespaced de notificaciones Claude remotas con eventos mínimos,
  autenticados y deduplicados, sin prompts ni respuestas.
- Rail compacto con flyout por caja y tarjeta horizontal con nombre, número de
  ventanas y badge LOCAL/SSH; menús y accesos se comparten mediante acciones comunes.
- Iconografía generada desde una única imagen canónica documentada en
  `design/UniConnect.icon/SOURCE.md`.

## Contratos de recuperación

Cerrar una ventana no equivale a borrar su registro ni a matar el tmux remoto.
Los identificadores de sesión, cwd, comando de arranque y metadatos necesarios para
reanudar se persisten juntos. Si un cwd local desaparece, se utiliza una ubicación
segura y la interfaz solicita reasignarlo. Si un tmux remoto no existe, la ventana se
mantiene recuperable y se muestra el error: restaurar nunca crea silenciosamente un
reemplazo vacío.

La recuperación detallada y los pasos de rollback están en
[`UNICONNECT-RECOVERY.md`](UNICONNECT-RECOVERY.md). La separación y migración manual
desde cmux están en [`UNICONNECT-CMUX-MIGRATION.md`](UNICONNECT-CMUX-MIGRATION.md).

## Seguridad y secretos

- Los comandos SSH completos no se copian a snapshots, preview, journal o logs.
- `sshpass`, cuando es imprescindible, recibe la contraseña fuera de argv.
- Las conexiones importadas se validan como `ssh` o `sshpass` que invoque realmente
  `ssh`; se rechazan pipes, sustituciones y encadenamientos.
- Los hooks remotos se fusionan sin reemplazar la configuración del usuario y se
  pueden retirar de forma namespaced.
- `StrictHostKeyChecking=accept-new` acepta una clave nueva pero sigue rechazando
  cambios de identidad del servidor. Su riesgo está documentado en el threat model.
- El árbol actual se somete a un escaneo de secretos con redacción antes del push.
  Un secreto que apareció en historia publicada debe rotarse; la historia no se
  reescribe sin autorización expresa.

## Firma e instalación

Los instaladores verifican identidad y designated requirement antes de modificar
`/Applications`. Una firma ad-hoc no es una identidad estable y se rechaza para la
instalación final. La Release candidata se firmará siempre con la identidad Apple
Development estable del propietario y se validará antes de solicitar permiso de
instalación.

UniConnect instalada permanece abierta durante todo el desarrollo. Solo tras build,
tests, auditorías, commits y push se solicitará una autorización única para cerrarla,
hacer un backup recuperable, instalar la Release y ejecutar la comprobación visual.

## Validación final

Inventario privado de la fase 2 del Escritorio completado en modo estrictamente
`dryRun`, sin mover, renombrar, editar ni borrar archivos:

- ruta privada: `/Users/danielgomezmartin/.uniconnect/backups/desktop-phase2-20260904T064133Z`;
- manifiesto SHA-256: `c811a36ac36ea74bd87f3a3eb289209fb2e2c3d43e7aa6cf7119aaf5310c096e`;
- seis operaciones propuestas, cero entradas ilegibles y permisos `0700`/`0600`;
- `IMPUESTOS` y el traslado opcional de `PongFrenetico` siguen pendientes de una
  decisión separada; el script de rollback no se ha ejecutado.

Pendiente de completar en este candidato:

- build Debug aislada y build Release firmada;
- suites focales y completa, con recuentos exactos;
- preview sanitizado de una copia de `CONNECT.md`;
- comprobaciones SSH/tmux exclusivamente de lectura sobre destinos reales;
- E2E con sesiones sacrificables para updater y bridge;
- auditorías finales de localización, independencia de cmux y secretos;
- commits del repositorio principal y push de la rama;
- instalación y validación visual, únicamente después de la autorización del usuario.

Los resultados, hashes, rutas de artefactos y cualquier riesgo residual real se
registrarán aquí al concluir cada comprobación. No se reutilizan cifras de builds o
E2E antiguos como evidencia de este candidato.
