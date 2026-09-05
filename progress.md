# Progreso coordinado de UniConnect

Actualizado: 2026-09-05. Resumen compartible; no incluir credenciales, comandos
de conexión, UUID de conversaciones ni capturas privadas.

## Ramas y coordinación

- Repositorio: `Unixcision/uniconnect`. Principal: `uniconnect`.
- Rama única de entrega: `uniconnect`. El 2026-09-05 se incorporó por avance
  directo y se publicó `fa91daa4c` desde `desarrollo/multiplataforma`, incluidos
  todos los cambios Linux, el catálogo compartido y español `29a8edec3e`.
- Retirada `desarrollo/multiplataforma` después de verificar el SHA incorporado.
  Sus commits permanecen en la principal; no se han eliminado ramas upstream.
- Incorporado también el trabajo de `desarrollo/monitor-ramas` hasta `702f05309`:
  monitor instalado en Linux y revisión de la otra consola. Su único conflicto
  era este estado; se conservan las evidencias de ambos equipos y el CI actual.
- Inventario remoto: 1.818 ramas vigentes, ninguna contenía `progress.md`
  antes de crear este documento. Es un inventario histórico: ahora se revisan
  también los estados nuevos de otros equipos. Sus cambios locales no pueden
  darse por incorporados hasta publicarse.
- Todo el trabajo del equipo Linux está subido; no hay borradores pendientes
  de sus tres colaboradores. No mezclar ramas heredadas de cmux por su nombre.
- Antes de integrar: traer los cambios remotos, leer los estados nuevos,
  comprobar CI y publicar sin forzar. En consultas `gh`, indicar explícitamente
  `--repo Unixcision/uniconnect` para no apuntar al upstream implícito del fork.

## Entregado y comprobado

- Una aplicación Mac/Linux, recursos compartidos y producto solo en español.
- Catálogo único de sintaxis de reanudación para 17 proveedores. Swift y Python
  consumen el mismo recurso; se conservan las políticas de permisos existentes.
- Importación y edición SSH de Linux preparan clientes tmux, verifican su unión
  antes de publicar y conservan los originales ante cancelación o rollback.
- Cifrado Linux con apertura automática, sin contraseña de arranque.
- VM Linux: 107 pruebas correctas, incluidos los fallos/crashes y GTK/VTE real.
- CI macOS y Ubuntu: 82 pruebas Launch y 8 Vault correctas en cada sistema,
  incluida una CLI real reubicada sin dependencia del directorio de compilación.
- CI `33981170986` completamente verde: Linux ejecutó 107 pruebas, con cuatro
  omisiones esperadas por necesitar el backend root `systemd-creds`.

## Validación e integración pendientes

- El fallo de `PYTHONPATH` en `33973077181` está resuelto: la ejecución
  [33981170986](https://github.com/Unixcision/uniconnect/actions/runs/33981170986)
  de `fa91daa4c` terminó correctamente en macOS y Ubuntu.
- Compilación macOS Debug etiquetada y `cmux-unit build-for-testing` correctas.
  CI móvil [33983039150](https://github.com/Unixcision/uniconnect/actions/runs/33983039150)
  correcto, incluidos dominio, tmux real aislado y Android. No demuestra paridad
  completa de interfaces ni la ejecución de toda la suite GUI macOS.
- Runtime Linux actualizado y reabierto con `c1ea46a48b`; detalle de instalación
  y comprobaciones en el bloque de responsables, sin sustituir sesiones tmux.
- Pixel físico: APK instalada; autorización desde Mac, árbol, pantalla en directo,
  texto e Intro confirmados en la misma terminal. Avisos en segundo plano,
  deduplicación al reconectar y apertura del destino exacto comprobados contra
  Debug aislado. Reposo profundo y revocación manual siguen pendientes.
- Linux ya produce el render-grid móvil compartido; adaptación y pruebas listas
  para CI. Falta demostrar Android contra un Linux real. Capturas GTK en CI
  verifican el diseño, no conexiones SSH. No confundir esta base con la Release.
- Arranque en frío Mac corregido en `4130aa3ab`: `is_ready:false` espera el primer
  evento completo con plazo cancelable, sin crear otra ventana ni repetir entrada.
  La prueba roja `6031e5193` demostró el error. La APK está instalada; el Pixel
  se ha bloqueado y queda pendiente la última apertura física.
- Recuperación de locales antiguas en `693452686`: al restaurar el runtime se
  añade tmux conservando identidad, carpeta e historial/IA; guardar la PTY viva
  sigue sin migrarla. Debug y test target compilan; aceptación de restauración
  y Release final pendientes. No se ha tocado la instalación en uso.
- Nuevos encargos: mantener el diseño aprobado del Mac, modernizar Linux con
  esa identidad visual y consolidar cambios revisados en la principal.
  Detalle y criterios de cierre: [MULTIPLATAFORMA_PLAN.md](docs/MULTIPLATAFORMA_PLAN.md).
- Continúan pendientes la convergencia del coordinador de transacciones con Mac,
  ciclo completo de agentes, bridge autenticado y otras diferencias documentadas
  en `linux/PORT_STATUS.md` y `docs/CROSS-PLATFORM.md`.
- Ajuste de ejecución solicitado: cerrar los cambios abiertos con comprobaciones
  del fallo concreto; no abrir refactors ni rediseños adicionales del Mac.

## Monitor de coordinación

Monitor de ramas instalado en el servidor: comprobaciones cada dos minutos,
sin modelo cuando nada cambia, eventos privados y entrega mediante `codex queue`.
La entrega y revisión automática al quedar libre esta sesión ya se observaron.
No se garantiza despertar una sesión cerrada. Alcance y operación en
`docs/BRANCH-MONITOR.md`; no hace merges por sí mismo ni cambia principal.
Validación: suite Linux de 126 pruebas correcta antes del endurecimiento final;
24 pruebas aisladas del monitor/notificador verifican también rutas, recuperación
tras caída, archivos privados y reintentos. Ninguna prueba unitaria envía avisos.

## Hallazgos para coordinar con el equipo de principal

Revisión estática de la otra consola del código publicado hasta `3dec8ef137`; no se han ejecutado
pruebas sobre dispositivos, abierto listeners ni enviado entradas a terminales.
Estos hallazgos no autorizan a cambiar credenciales ni sesiones del usuario.

1. **Activación móvil importable en Linux.** `linux/uniconnect/imports.py`
   incorpora cualquier ajuste ausente mediante `setdefault` (líneas 291–294).
   Un snapshot con `settings.mobileHostEnabled=true` puede así introducir ese
   valor en un perfil que aún no lo contiene. `mobile_desktop.py` (líneas 27–28)
   lo utiliza para iniciar el listener en el próximo arranque, sin activar la
   opción localmente. Sigue limitado a Tailscale y requiere dispositivos aprobados;
   no se ha demostrado acceso no autorizado. Propuesta: separar el consentimiento
   local de los ajustes importables, incluyendo restauración, y probar que un
   snapshot ajeno no encienda el listener ni borre una elección local explícita.
2. **Un frame obsoleto cancela un replay necesario en Android.** En
   `android/app/src/main/java/com/unixcision/uniconnect/android/data/NativeMachineClient.kt`
   (línea 56), cualquier frame `full` pone `needsReplay=false`, aunque
   `domain/TerminalFrame.kt` lo descarte por revisión antigua. Caso concreto:
   pantalla rev10/80 columnas; delta rev11/100 columnas exige replay; full rev9
   devuelve la pantalla rev10 y borra la necesidad de replay. Si cesan los eventos,
   queda una pantalla antigua. Propuesta: solo satisfacer el replay con un full
   aceptado que cubra la revisión requerida; añadir una prueba de esa secuencia.

El fallo anterior del test tmux Mac por `/var` frente a `/private/var` **ya está
corregido en principal** (`99d5b9d3be`, CI `33982840288` completa en verde). No
duplicar ese arreglo. Para `3dec8ef137`, español y dominio/protocolo pasan; Android
seguía ejecutándose en CI `33983039150` durante esta revisión. No atribuir al
nuevo HEAD resultados de commits anteriores. Ambos hallazgos están reconocidos
por el equipo principal: pruebas rojas publicadas en `a845ee06b` (consentimiento)
y `080dfddd8` (replay), corregidas en `b5455fdcd` y `be867fea0` respectivamente.
CI de núcleo compartido `33985149672` y móvil `33985212249` correctos.
`progress.md` reconciliado.
Continuar sobre `uniconnect`; no crear otra línea de entrega Linux. Antes de
cambiar el checkout del Linux activo, conservar sus procesos/estado y comprobar
que no haya nuevos cambios locales ni remotos.

### Hallazgo adicional del catálogo Mac (`9f8365fc9`)

En espacios sin `uniConnectProfile`, `v2MobileWorkspaceList` anuncia agentes
locales, pero el fallback de `v2MobileTerminalCreate` crea una terminal genérica
sin aplicar `agent`, `name` ni `directory`. El selector Android recién publicado
expone esa discrepancia: una elección explícita de agente puede recibir una shell
con respuesta de éxito. Contraste estático de `Sources/TerminalController.swift`
y el constructor de `Workspace`; no reproducción sobre el Mac del usuario.
Pendiente coordinar que el catálogo anuncie solo capacidades realmente admitidas
y que la creación no ignore parámetros explícitos. No se modificó el host Mac
ni el frontend Android para este hallazgo; Linux no usa ese fallback.

## Responsables de este bloque

Actualización Mac, 2026-09-05 21:05 CEST:

- El usuario asume el frontend/diseño Android. No seguir retocándolo desde esta
  consola. `9f8365fc9` publica el selector del catálogo real de agentes y el
  compositor que ya estaba terminado (texto + Intro en una petición, borrado
  solo tras confirmación). APK y fuentes de pruebas compilan; no se ha instalado
  esta APK. Recursos Android españoles parseados, sin referencias ausentes.
- Release universal del Mac compilada y firmada con la misma identidad instalada;
  dry-run del instalador correcto. **No instalada**, producción y sesiones intactas.
- Debug aislado: primera lectura fría `is_ready:false`, después cuadrícula real
  lista sin crear otra terminal. No confundirlo con migración local ya validada.
- Linux real, sustitución solicitada por el usuario: checkout en `uniconnect`,
  código `c1ea46a48b` instalado y GUI reabierta. Todas las ramas propias ya están
  incluidas en principal; no se fusionaron ni borraron ramas heredadas.
  Instalador y lanzador actualizados con `wcwidth==0.2.13` en entorno privado,
  sin cambiar el Python del sistema. Validación aislada: 186 pruebas sin fallos,
  una omisión reservada a CI; núcleo Mac/Linux `33985991660`, español y capturas
  de ese mismo SHA correctos. Android `9f8365fc9`, CI `33985907727`, correcto.
  Cierre ordenado de la GUI anterior y copia privada coherente antes del cambio.
  Las seis cajas y quince ventanas conservan IDs, tmux, agentes e historial
  (huella comparada antes/después); las dos superficies de la caja visible
  responden en ejecución, las otras trece están guardadas sin abrirlas como prueba.
  Mismo estado y vault, cifrado con desbloqueo automático y sin contraseña de
  arranque; idioma español y listener móvil desactivado conservados. No se
  reiniciaron procesos dentro de tmux ni se reimportó configuración. El monitor
  mantiene su instalación independiente. Esto no valida Android contra Linux real.
- Siguiente trabajo de esta consola: instalación protegida, recuperación local
  tmux y Android contra Linux real. Chat real propuesto, **no implementado**;
  requiere historial por identidad de conversación, no convertir texto de la
  consola en mensajes ni arrancar una segunda IA.

- Coordinación principal: inventario, integración Git y estado compartido.
- `linux_state`: inventario de todas las ramas y pruebas transaccionales.
- `linux_transport`: catálogo compartido, empaquetado y revisión de CI Mac/Linux.
- `remote_inventory`: contraste de notas locales y límites de la evidencia.

Los estados históricos privados de cada equipo no sustituyen este resumen.
Al terminar un bloque, publicar el commit y actualizar solo su estado vigente.

## Coordinación Mac/Linux · 2026-09-05 21:38 CEST

- Astra/root publica la observación de IDs nativos Claude/Codex en los nuevos
  lanzamientos Linux: señal del agente → metadatos del pane → registro e historial
  existentes. No se reinician agentes antiguos para obtener un ID. Hasta recibir
  la señal se muestra el estado pendiente; en Codex puede tardar un primer turno.
  Pruebas de integración preparadas para CI, no ejecutadas localmente. El `notify`
  de Codex se limita a esa invocación y sustituye uno personalizado previo;
  no cambia configuraciones globales ni las notificaciones integradas de la TUI.
- Se reserva a Huygens la activación y aprobación móvil del Linux actual por la
  interfaz local, únicamente para el Pixel ya conocido en Tailscale. De momento
  está en inspección: acceso móvil desactivado, cero dispositivos aprobados.
  No cambiar checkout, reiniciar GUI/tmux, reimportar estados ni abrir las quince
  ventanas como prueba. El otro equipo debe registrar cualquier intervención en
  este mismo apartado antes de modificar ese runtime.
- El Linux actualizado fue verificado independientemente: quince panes remotos
  conservan todos sus PIDs; seis espacios y quince registros mantienen IDs,
  agentes, tmux e historial. Solo dos superficies GUI están abiertas y las otras
  trece siguen guardadas. No confundir este resultado con Android/Linux validado.
- La instalación Mac abortó antes de sustituir `/Applications/UniConnect.app`
  porque la aplicación seguía abierta con un formulario «Nueva ventana». Hay
  copia privada de estado y aplicación. No se canceló el formulario ni se forzó
  el cierre. Pendiente completar esa interacción y coordinar el código actual.
- Otra consola modifica primera ventana Mac/Linux y frontend/teclas Android.
  Esos cambios se dejan intactos y fuera del commit de identidad. Galileo preparó
  dos pruebas del RPC Mac para el fallo de agente/nombre/carpeta ignorados en un
  espacio genérico; sin fix de producción ni ejecución todavía. Confirmar dueño
  antes de editar los mismos tres Swift. El usuario conserva el frontend Android.
- La APK recién compilada sigue sin instalar; no reemplazar la que usa el usuario
  mientras trabaja en el diseño. El chat real continúa pendiente, no se simula a
  partir de la salida de terminal ni se inicia otra IA para representarlo.
