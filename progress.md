# Progreso coordinado de UniConnect

Actualizado: 2026-09-05. Resumen compartible; no incluir credenciales, comandos
de conexión, UUID de conversaciones ni capturas privadas.

## Ramas y coordinación

- Repositorio: `Unixcision/uniconnect`. Principal: `uniconnect`.
- Desarrollo conjunto Mac/Linux, no una línea Linux separada. La antigua rama
  `desarrollo/multiplataforma` se eliminó remotamente tras quedar su contenido en
  principal; no recrearla. Este bloque se publica en `desarrollo/monitor-ramas`.
- Trabajo funcional publicado: `25eec3eb13`; incluye el cambio de español
  `29a8edec3e`. Durante esta revisión, principal avanzó remotamente a
  `fa91daa4c2`: ya contiene el trabajo funcional y el arreglo de CI de desarrollo.
- Último avance principal revisado: `3dec8ef137`, con Android, acceso móvil y
  cambios visuales. Su progreso Android ya está publicado. Esta rama conserva
  el monitor; aún no incorpora ese avance porque el merge de prueba detecta un
  conflicto en este documento. Se pidió dirección al usuario; no se inició merge.
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

- No se ha validado la aplicación macOS completa con Xcode. El núcleo portable
  en verde no demuestra esa compilación ni la paridad completa de interfaces.
- El proceso GUI Linux ya abierto no fue reiniciado con los últimos commits.
- Ya se leyó `android/PROGRESS.md` de principal. Documenta pruebas reales parciales
  Mac/Pixel y trabajo pendiente; no demuestra paridad ni aceptación real de Linux.
- Continúan pendientes la convergencia del coordinador de transacciones con Mac,
  ciclo completo de agentes, bridge autenticado y otras diferencias documentadas
  en `linux/PORT_STATUS.md` y `docs/CROSS-PLATFORM.md`.

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

Revisión estática del código publicado hasta `3dec8ef137`; no se han ejecutado
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
nuevo HEAD resultados de commits anteriores. Quedan pendientes los dos hallazgos
de arriba y la decisión sobre cómo reconciliar `progress.md`; no promover principal.

## Responsables de este bloque

- Coordinación principal: inventario, integración Git y estado compartido.
- `linux_state`: inventario de todas las ramas y pruebas transaccionales.
- `linux_transport`: catálogo compartido, empaquetado y revisión de CI Mac/Linux.
- `remote_inventory`: contraste de notas locales y límites de la evidencia.

Los estados históricos privados de cada equipo no sustituyen este resumen.
Al terminar un bloque, publicar el commit y actualizar solo su estado vigente.
