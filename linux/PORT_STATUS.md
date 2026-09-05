# Estado de compatibilidad de UniConnect en Linux

Corte de auditoría: 2026-09-05. La edición Linux funciona como aplicación GTK/VTE con
espacios de trabajo persistentes, pero **la paridad 1:1 con macOS no está
demostrada y quedan funciones del contrato sin implementar**.

UniConnect es un solo producto Mac/Linux dentro de este repositorio; véase
[el desarrollo compartido](../docs/CROSS-PLATFORM.md). La lógica Python existente
todavía necesita converger con los servicios portables del original. Los textos
ya usan únicamente `Resources/Localizable.xcstrings`, sin diccionario Linux aparte.
Español es el único idioma del producto desde `29a8edec3`. El traductor de Linux
consume el catálogo español compartido; los ajustes y CLI ya no ofrecen otros
idiomas y normalizan las preferencias antiguas. No se cambia el idioma del
sistema ni de las herramientas del terminal.

Gate actual: **107 pruebas Linux correctas, 72,554 s**, con errores críticos GTK
tratados como fallos. Incluye cinco escenarios MainWindow aislados, dos de VTE
real y once del coordinador de transacciones, además de cifrado/arranque sin
contraseña, importación, transporte, reconexión y menús. No equivale a un build
completo macOS ni a una matriz SSH remota de todas las acciones.

Gate histórico antes de la primera publicación: **63 pruebas correctas, 37,885 s**.
Incluye nueve pruebas transaccionales con fallo/cierre inesperado y recuperación
del par estado/vault, más reconexión ante una caída real de tmux en una fixture.
El fallo de copiar selección de tmux 3.2a con ncurses 6.6 se reprodujo en un socket
aislado; `set-clipboard off` lo evitó manteniendo el buffer y el PID de la ventana.
La política afecta solo a los sockets propios; copiar en VTE sigue disponible.
También hay navegación por caja/ventana y número, fijado, movimiento de caja,
buscar siguiente/anterior, acciones de panel, contextuales de pestaña, reapertura
inmediata, ayuda y habilitación contextual comunes a menú/paleta/atajos.

Fuentes de requisitos: [arquitectura](../docs/UNICONNECT.md) y
[menús y atajos](../docs/MENUS.md), leídos completos. La referencia es esa
superficie de producto, no todas las funciones heredadas de cmux presentes en
el repositorio. Files, navegador, barra derecha, Diff Viewer y Task Manager
están expresamente excluidos del menú original: su ausencia no constituye una
deuda de este port. Tampoco se ha reorganizado el escritorio.

## Evidencia observada

- El JSON original se recuperó y se importaron **6 cajas / 15 ventanas** con
  identidades estables. Son cantidades importadas, no «15 flujos GUI probados».
- La ventana real de Linux mostró TTI con Astra y ambas pestañas TTI/TC
  conectadas. Captura privada fuera del repositorio:
  `/root/apps/UniConnect-migration/uniconnect-running.png`. La matriz de las
  seis cajas también han sido seleccionadas en la aplicación real: TTI, TotalVO,
  B2B, otros carriles, Docs/soporte y Gemini renderizan sus historiales. Los quince
  clientes SSH locales figuran conectados. La matriz completa de acciones sigue abierta.
- En el servidor SSH existen 15 sesiones del socket tmux `uniconnect`.
  La comprobación de las 12:28 UTC demostró 11 Codex y una conversación Agy
  recuperados por UUID, con bloqueos nativos poseídos por procesos descendientes
  de sus ventanas tmux. Las tres ventanas restantes esperaban a sus propietarios
  originales; no se duplicaron ni detuvieron esas conversaciones.
- `uniconnect-recovery.service` quedó habilitado y activo, con `Linger=yes`.
  Reiniciar solo el supervisor conservó los 15 PID de ventana. No se reinició
  el servidor. Los hashes del script y la unidad instalados coincidían con
  [scripts/](scripts/README.md).
- Las pruebas de [recuperación](tests/test_recovery.py) verificaron un bloqueo
  kernel real entre procesos hasta la salida normal del propietario y el
  rechazo de un destino tmux ajeno. Las de [transporte](tests/test_transport.py)
  usan tmux y SFTP reales aislados: creación idempotente, reconexión sin crear,
  preservación del proceso al cerrar cliente, progreso por bytes confirmados y
  limpieza de una transferencia cancelada.
- Gate anterior comunicado por el responsable de transporte/GUI tras integrar las
  correcciones: `PYTHONPATH=linux xvfb-run -a /usr/bin/python3 -X faulthandler
  -m unittest discover -s linux/tests -v`: **49 pruebas correctas, 26,227 s**.
  Incluye una fixture de seis cajas/siete terminales, 24 cambios de selección,
  renombrado, paneles, cierre/reapertura y ajustes. Es una prueba GTK/VTE real
  bajo Xvfb, distinta de la aceptación manual en el escritorio y de la matriz
  completa de funciones macOS. Incluye CLI/CONNECT/Agy, seis pruebas de
  reconexión automática y seis de portapapeles gráfico. La prueba del escritorio
  termina su proceso a la fuerza y acredita el mismo PID de tmux, contenido e
  identidad tras reabrir, con descifrado automático y sin contraseña.
- Gate adicional del responsable de estado/importación: `test_state` 14/14 y
  `test_imports` 8/8. CONNECT.md ya reconoce cajas Local/SSH en ES/EN,
  bloques SSH/sshpass, tablas, cwd y resumes; conserva diagnósticos por línea
  sin secretos, permite excluir filas y ofrece preflight de solo lectura.

## Desviación autorizada: cifrado sin contraseña de arranque

El usuario pidió explícitamente cifrado automático sin login ni contraseña al
abrir la aplicación. Esto sustituye la experiencia de autenticación de arranque
del original; no debe volver a introducirse como requisito de paridad.

[vault.py](uniconnect/vault.py) incorpora AES-GCM y una clave maestra envuelta por
`systemd-creds` para este equipo bajo root; el arranque de
[__main__.py](uniconnect/__main__.py) la abre sin diálogos y falla visiblemente
si no puede verificarla. El backend automático actual requiere root y
`systemd-creds`; no acredita desbloqueo automático universal en cualquier
distribución/cuenta Linux. Secret Service y envolturas con contraseña siguen
siendo formatos de compatibilidad/recuperación. Exportar un archivo portátil
con contraseña es una acción separada del arranque.

## Contratos conservados y límites de su evidencia

| Requisito | Estado del código y prueba disponible | Límite pendiente |
|---|---|---|
| Identidad propia y estado aislado | Identidad Linux propia; estado y vault separados. No se lee automáticamente el estado de cmux. CLI básica con socket privado y verificación del UID del cliente. | No existe aún equivalente completo del socket/control API y esquema URL del original. |
| Guardado duradero | `StateStore.save`, CAS sobre revisión en disco, bloqueo, escritura atómica, permisos privados y tick GUI de ocho segundos. Pruebas de identidad de diccionarios y otro escritor en `test_state`; escritorio reabierto tras crash real en `test_control`. | No equivale a recuperación probada ante todos los puntos de corte del proceso. |
| Caja/ventana y cierre | Identidades, orden, selección, registros de historial importados y reapertura persistidos. Cerrar el cliente conserva tmux. | No hay interfaz completa de historial de conversaciones ni límites/acciones del menú de cerradas del original. |
| SSH y tmux exactos | Parser SSH/sshpass, separación de secretos, target guardado, `has-session` antes de attach, socket aislado, mouse e historial. Seis reintentos automáticos acotados a 60 s para salida 255; presupuesto restablecido tras un minuto estable, con seis pruebas. | Falta la matriz de caída de red real sobre el servidor de trabajo; las salidas y timers se ejercitan de forma determinista en GTK/VTE. |
| Reconexión forzada | Superficie VTE conservada; generaciones y espera de salida del hijo anterior; prueba de ráfaga de reconexiones. | Falta matriz de caída de red real, reapertura de importaciones y alias/credenciales concurrentes en GUI. |
| Revisiones de credenciales | IDs de vault inmutables; edición GUI prepara todos los reemplazos y exige cliente tmux vivo con nonce antes de guardar/retirar originales. Cancelación y rollback conservan los clientes, referencias, estado y vault originales. | La matriz del cambio de endpoint SSH sobre red real sigue pendiente; las pruebas GUI usan clientes tmux locales aislados. La política debe converger con Mac. |
| Copias automáticas | Seis horas, siete días, máximo 28 programadas; snapshot y vault compañero con hash. Diario privado, cápsula cifrada, rollback byte-exacto y recuperación al arrancar. Importación/edición SSH añaden verificación de clientes y rollback GUI. | Restaurar una copia desde su menú aún usa la transacción de archivos, sin preparación equivalente de clientes. |
| JSON de configuración | Preview sin ejecutar comandos, identidades estables, reimportación idempotente, JSON Linux/macOS y exportación AES-GCM. JSON real aplicado. | Preview inmutable no basta para el contrato completo CONNECT.md; ver fila específica debajo. |
| Archivos arrastrados/subidos | Drop de URI; SFTP con bytes confirmados, cancelación, timeout y limpieza. Imágenes del portapapeles convertidas a PNG privado, con routing Local/SSH y caché acotada; seis pruebas de GTK con píxeles y bytes originales. | Falta matriz GUI completa de imagen, cancelación y fallo de la conexión SSH de trabajo. |
| Terminal y paneles básicos | VTE, copiar/pegar texto, búsqueda básica, fuente, pestañas reordenables y división horizontal/vertical. | La estructura actual usa ejes y paneles más simples; no acredita las operaciones Bonsplit completas ni paridad visual/teclado/IME/Ghostty. |

## Funciones parciales o faltantes de la superficie original

| Área | Falta o diferencia verificable |
|---|---|
| Ciclo de agentes | «Nueva conversación en otra ventana» hereda carpeta, conexión y socket tmux de la ventana local/SSH, pero crea una identidad independiente sin copiar el ID de conversación. Menú, paleta y contextual comparten esta acción; la ventana anterior sigue viva. El selector también admite un comando personalizado como ejecutable y argumentos, no como texto enviado al agente actual. Siguen pendientes cambiar de agente en la misma ventana, seleccionar una conversación histórica, bifurcar y descubrir continuamente los IDs nuevos. Los flags de permisos/trust del original tampoco están reproducidos ni verificados. |
| Reanudación Agy genérica | El bootstrap importado y la política genérica ya usan `agy --conversation`; Gemini está reanudado con su UUID y se ha renderizado en la app real. Falta ampliar la matriz del selector genérico local. |
| Duplicados y raíz local ausente | Hay ownership por endpoint/tmux/sesión y rechazo de duplicados; falta conservar el duplicado como shell recuperable con reanudación manual. Una raíz ausente ya abre una consola segura sin agente ni perfiles; falta la reasignación persistida de todos los registros afectados. |
| CONNECT.md | Parser, selección y preflight con once pruebas; un guardado periódico no invalida el plan, una edición real sí. La GUI aplica mediante preparación de clientes tmux, diario cifrado y rollback de procesos. Faltan la matriz completa Markdown→diálogo→SSH real y la convergencia del mismo contrato con Mac. Un registro local sin tmux existente se rechaza antes de ejecutar agentes. |
| Actualizar Claude | No hay orquestador recuperable por ventana/caja/host, inspección de versiones, actualización única por host ni restauración tras éxito/fallo. No existe la familia de acciones original. |
| Bridge de notificaciones | Las notificaciones actuales proceden de la campana VTE. No está integrado el hook remoto autenticado, correlación estable, transporte loopback, deduplicación durable ni navegación del clic de una notificación del sistema a su destino exacto. El centro y la API móvil ya comparten un historial persistente. |
| Notificaciones: acciones | El centro abre el destino exacto, marca todo, salta a la última no leída, alterna leído/no leído por caja/terminal y descarta entradas. Menú, paleta y contextuales usan acciones compartidas, guardado con rollback y protección del foco contextual. Seis pruebas de comportamiento incorporadas en `693452686` y verificadas en CI. Sigue pendiente el menú de estado equivalente al de macOS. |
| Raíl y grupos | El modo compacto muestra iniciales y tooltip. No tiene flyout horizontal con elección individual de ventanas, grupos jerárquicos, plegado, fijado, multiselección ni badges completos del bridge/desconexión. |
| Menús compartidos | Catálogo común de menú/paleta/contextuales con iconos, atajos visibles y habilitación según el contexto. El inventario de `MENUS.md` aún no está completo; familias de agentes, grupos y bridge siguen pendientes. |
| Archivo | Reabrir la última cerrada, cerrar otras/izquierda/derecha y confirmaciones ya están presentes. Faltan eliminar/vaciar cerradas, migración explícita autenticada desde cmux y guardar plantilla inicial. |
| Edición y paneles | Búsqueda siguiente/anterior, selección, Ctrl-F, igualar/ampliar/restaurar y navegación direccional tienen acciones. Faltan modo copia por teclado, movimiento entre paneles y la matriz completa de equivalencia con Bonsplit. |
| Caja y pestañas | Fijado, movimiento por posición, navegación anterior/siguiente y numérica, reset del nombre y contextual de pestaña presentes. Faltan grupos y la matriz completa de selección múltiple. |
| Ajustes y ayuda | Hay tema/fuente/atajos configurables, idioma español fijo y rutas de ayuda. No hay configuración terminal equivalente a Ghostty ni updater de aplicación. Los defaults de teclado están adaptados a Ctrl; falta la matriz completa de estos menús y contextos. |
| Escritorio Linux | Lanzador y `.desktop` propios presentes. No hay superficie equivalente completa del Dock/menú de estado, atajo global de mostrar/ocultar ni registro demostrado de `uniconnect://`. Firma Apple y AppKit son específicos de macOS; no se atribuye esa verificación a Linux. |
| Idiomas y apariencia | Catálogo compartido únicamente en español; preferencias antiguas normalizadas. CI verifica traducción, CLI y menús GTK reales. Queda revisar mensajes de error menos frecuentes y la matriz claro/oscuro/sistema, accesibilidad y tamaños; VTE trata sistema como oscuro actualmente. |
| CLI/API | `uniconnect-cli`/`cmux` ofrece list/select/focus/send/read-screen/reconnect/close/persist y está integrado y probado contra GTK real. Eso no acredita todos los protocolos/comandos del original. |

## Criterio de cierre

Mantener separadas la instalación útil actual, las funciones implementadas con
pruebas proporcionadas y la paridad completa. Para cerrar 1:1 se necesita terminar
las filas pendientes que pertenecen al contrato original, incorporar las
correcciones en curso, pasar el gate final y verificar la interfaz real en las
acciones y contextos pertinentes. Los procesos originales aún abiertos deben
conservarse; su espera no autoriza duplicarlos para obtener una demostración.
