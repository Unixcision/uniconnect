# Progreso coordinado de UniConnect

Actualizado: 2026-09-05. Resumen compartible; no incluir credenciales, comandos
de conexión, UUID de conversaciones ni capturas privadas.

## Ramas y coordinación

- Repositorio: `Unixcision/uniconnect`. Principal: `uniconnect`.
- Rama única de entrega: `uniconnect`. El 2026-09-05 se incorporó por avance
  directo y se publicó `fa91daa4c` desde `desarrollo/multiplataforma`, incluidos
  todos los cambios Linux, el catálogo compartido y español `29a8edec3e`.
- El usuario ha pedido retirar `desarrollo/multiplataforma` tras esa integración;
  la eliminación se realiza condicionada a su SHA incorporado para no borrar
  trabajo remoto nuevo. Los commits permanecen en la principal.
- Inventario remoto: 1.818 ramas vigentes, ninguna contenía `progress.md`
  antes de crear este documento. No se han encontrado estados publicados de
  otros equipos. Sus cambios locales no pueden darse por incorporados.
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

## Validación e integración pendientes

- El fallo de `PYTHONPATH` en `33973077181` está resuelto: la ejecución
  [33981170986](https://github.com/Unixcision/uniconnect/actions/runs/33981170986)
  de `fa91daa4c` terminó correctamente en macOS y Ubuntu.
- No se ha validado la aplicación macOS completa con Xcode. El núcleo portable
  en verde no demuestra esa compilación ni la paridad completa de interfaces.
- El proceso GUI Linux ya abierto no fue reiniciado con los últimos commits.
- En curso en el Mac: Android nativo, autorización propia por IP Tailscale,
  terminales locales durables y notificaciones móviles. Primera APK instalada
  en Pixel físico; no confundir esta base en desarrollo con la Release instalada.
- Nuevos encargos: mantener el diseño aprobado del Mac, modernizar Linux con
  esa identidad visual y consolidar cambios revisados en la principal.
  Detalle y criterios de cierre: [MULTIPLATAFORMA_PLAN.md](docs/MULTIPLATAFORMA_PLAN.md).
- Continúan pendientes la convergencia del coordinador de transacciones con Mac,
  ciclo completo de agentes, bridge autenticado y otras diferencias documentadas
  en `linux/PORT_STATUS.md` y `docs/CROSS-PLATFORM.md`.

## Responsables de este bloque

- Coordinación principal: inventario, integración Git y estado compartido.
- `linux_state`: inventario de todas las ramas y pruebas transaccionales.
- `linux_transport`: catálogo compartido, empaquetado y revisión de CI Mac/Linux.
- `remote_inventory`: contraste de notas locales y límites de la evidencia.

Los estados históricos privados de cada equipo no sustituyen este resumen.
Al terminar un bloque, publicar el commit y actualizar solo su estado vigente.
