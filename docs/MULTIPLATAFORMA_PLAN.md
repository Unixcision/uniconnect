# UniConnect: objetivo multiplataforma

Contrato de trabajo y evidencias, 2026-09-05. Una fila pendiente no se considera
terminada porque exista una pantalla, un DTO o una compilación correcta.

## Decisiones del producto

- macOS, Linux y Android: español como único idioma de UniConnect. No cambiar el
  idioma del sistema, de las herramientas ni de las conversaciones del terminal.
- Android nativo (Kotlin/Compose), con el logo real y la paleta oscura azul,
  cian y violeta del Mac. Carga inicial ligada a trabajo real, sin demora ficticia.
- Red privada Tailscale ya instalada por el usuario. Conexión directa a IP o
  MagicDNS; sin Stack Auth, cuenta de cmux, intermediario web ni login adicional.
- UniConnect autoriza localmente el dispositivo observado en la conexión.
  El servidor escucha solo en su dirección Tailscale verificada. Una dirección
  no aprobada no puede leer espacios ni terminales. Revocar corta el acceso vivo.
- Jerarquía: máquina → espacios de trabajo → ventanas terminales. El teléfono
  opera las mismas sesiones, no copias. Su selección no roba el foco al escritorio.
- macOS y Linux mantienen la misma funcionalidad de producto descrita en
  [MENUS.md](MENUS.md), con adaptadores nativos de UI y sistema operativo.
- Terminales locales durables en tmux, conservando IA e identidad de conversación.
  Las sesiones antiguas activas no se migran silenciosamente ni se reinician.
- Un repositorio y una historia de entrega. Integrar las ramas propias por
  fast-forward o merge revisado; nunca pisar trabajo ajeno ni hacer force-push.
- El diseño actual del Mac queda aprobado: no seguir retocándolo por iniciativa
  propia. El rediseño móvil se refiere al Pixel 8 Pro / Android.
- Modernizar también Linux con la misma identidad azul noche/cian/violeta:
  reducir barras redundantes, ordenar cabecera y acciones, márgenes simétricos,
  sidebar limpio y estados legibles. Usar sus widgets nativos; no cambiar el
  motor de terminal para un cambio visual.
- Consolidar `desarrollo/multiplataforma` en `uniconnect` y retirar aquella rama
  solo cuando todos sus commits estén incorporados y publicados. No borrar ramas
  históricas upstream cuyo nombre contenga Linux.
- Vigilar los cambios remotos durante esta sesión y revisar cada avance antes de
  integrarlo. El monitor es de lectura: no hace merges, resets ni instalaciones.
- Delegar trabajo mecánico acotado a Claude Code cuando sea útil; comprobaciones
  proporcionales al riesgo, sin añadir arquitecturas o baterías de pruebas ajenas
  al fallo. Las pruebas automatizadas continúan en CI, no en sesiones del usuario.

## Evidencia y pendientes

| Requisito | Estado demostrado / evidencia exigida para cerrar |
| --- | --- |
| Español macOS/Linux | Publicado en `29a8edec3`; CI [33971595499](https://github.com/Unixcision/uniconnect/actions/runs/33971595499): 42 pruebas de ajustes, 4 de traducción/CLI, 1 GTK real y comprobación del catálogo compilado. Release instalada aún anterior. |
| Ramas de desarrollo | `fa91daa4c` incorporado y publicado en `uniconnect`; retirada `desarrollo/multiplataforma` después de comprobar el SHA. Se conservan sus commits y el histórico upstream ajeno. |
| Android nativo | APK y 17 pruebas compiladas, instalada en Pixel físico. Aprobación y listado Mac observados; terminal, entrada y reconexión en validación. |
| Acceso propio Mac | Listener activo exclusivamente en la IP Tailscale. Pixel rechazado antes de aprobarlo y autorizado desde la propia interfaz. No usa login externo. Falta comprobar revocación y recuperación completas. |
| Acceso propio Linux | Adaptador TCP propio implementado sobre el estado/superficies existentes; aprobación local, creación explícita y avisos. Falta adaptar captura tmux al render-grid móvil; no hay control visual Android/Linux demostrado todavía. |
| Árbol completo | Agregar todas las ventanas nativas del host; actualizar altas/bajas/nombres sin listas paralelas divergentes. Selección móvil independiente. |
| Terminal móvil | Entrada, teclas, salida, colores/TUI, tamaño, scroll, teclado y reconexión contra sesiones reales en las dos plataformas. No crear un shell por conectar o seleccionar. |
| tmux local Mac | En implementación: binding persistido, creación/recuperación, no duplicar IA, atribución de hooks a la superficie reenganchada y fallback explícito. |
| tmux local Linux | Backend existente; comprobar equivalencia de recuperación, metadatos/IA y sesión compartida con Android. |
| Modales y acciones | Crear/editar/cerrar/restablecer local y SSH por camino compartido desde todos los menús. Nombres, tmux, ruta y conversación coherentes. |
| Paridad funcional | Auditar y cerrar deudas reales de [PORT_STATUS.md](../linux/PORT_STATUS.md), no inferir paridad de un protocolo compartido. |
| Persistencia | Reinicios de app/red sin perder tmux ni duplicar PID/UUID de agente; proteger estado vivo y copia previa a instalar. |
| Robustez | Límites de colas/frames, cliente lento, red interrumpida, deltas perdidos, revocación y ausencia de interfaces Tailscale. |
| Notificaciones Android | Añadido por el usuario: eventos de sesiones de las máquinas autorizadas, abrir la ventana exacta, permiso nativo, deduplicación y recuperación tras cortes; validar con pantalla apagada/Doze, no solo con la app abierta. Sin proveedor cloud añadido por defecto. |
| Diseño Linux | Hoja CSS GTK nativa incorporada y conectada: paleta azul noche/cian/violeta, radios, estados y márgenes. Mantiene VTE y sus acciones. Validación visual Linux real pendiente. |
| Vigilancia del repo | Monitor de lectura activo cada 45 s durante esta sesión; el avance `fa91daa4c` se revisó e integró. Auditoría de paquetes compartidos delegada a Claude Code; CI macOS/Ubuntu `33981170986` correcto. |
| Entrega | CI relevante por plataforma, builds nativos, aceptación en Pixel/Mac/Linux, consolidación y Release instalada sin copias de desarrollo sobrantes del agente. |

## Validación y protección del trabajo vivo

Las pruebas automatizadas se ejecutan en CI o VM, no en el Mac del usuario.
Los builds locales usan `scripts/reload.sh --tag astra-chrome-final`, sin abrir
un Debug sin etiqueta. Android se valida en el dispositivo ADB autorizado.
No usar las conversaciones ni los tmux del usuario como fixtures destructivos.
No volcar contraseñas, claves, comandos SSH privados o transcripciones en Git.

Checkpoint actual: `cmux-unit build-for-testing` correcto con directorio aislado,
incluidos los archivos nuevos de pruebas; `CMUXMobileCore --build-tests` correcto.
Son compilaciones, no ejecuciones de pruebas. El workflow
`uniconnect-mobile.yml` ejecutará en CI protocolo, autorizaciones, tmux aislado
y pruebas Android. La última Release de uso diario sigue intacta.

El código de red conserva los identificadores y la representación de pantalla
existentes; no depende de los nombres históricos internos de paquetes o del CLI.
Esos nombres no implican usar servicios de cmux ni eliminan las licencias de las
dependencias de código abierto.
