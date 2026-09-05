# Progreso coordinado de UniConnect

Actualizado: 2026-09-05. Resumen compartible; no incluir credenciales, comandos
de conexión, UUID de conversaciones ni capturas privadas.

## Ramas y coordinación

- Repositorio: `Unixcision/uniconnect`. Principal: `uniconnect`.
- Desarrollo conjunto: `desarrollo/multiplataforma`, no una línea Linux separada.
- Trabajo funcional publicado: `25eec3eb13`; incluye el cambio de español
  `29a8edec3e`. Durante esta revisión, principal avanzó remotamente a
  `fa91daa4c2`: ya contiene el trabajo funcional y el arreglo de CI de desarrollo.
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
- CI `33981170986` completamente verde: Linux ejecutó 107 pruebas, con cuatro
  omisiones esperadas por necesitar el backend root `systemd-creds`.

## Validación e integración pendientes

- No se ha validado la aplicación macOS completa con Xcode. El núcleo portable
  en verde no demuestra esa compilación ni la paridad completa de interfaces.
- El proceso GUI Linux ya abierto no fue reiniciado con los últimos commits.
- Falta conocer/publicar el progreso local de los otros equipos antes de afirmar
  que todos sus cambios están unificados; principal sí incorporó nuestro bloque.
- Continúan pendientes la convergencia del coordinador de transacciones con Mac,
  ciclo completo de agentes, bridge autenticado y otras diferencias documentadas
  en `linux/PORT_STATUS.md` y `docs/CROSS-PLATFORM.md`.

## Monitor de coordinación

Monitor de ramas instalado en el servidor: comprobaciones cada dos minutos,
sin modelo cuando nada cambia, eventos privados y entrega mediante `codex queue`.
La cola acepta los avisos; queda observar su ejecución al quedar libre la sesión.
No se garantiza despertar una sesión cerrada. Alcance y operación en
`docs/BRANCH-MONITOR.md`; no hace merges por sí mismo ni cambia principal.
Validación: suite Linux de 126 pruebas correcta antes del endurecimiento final;
24 pruebas aisladas del monitor/notificador verifican también rutas, recuperación
tras caída, archivos privados y reintentos. Ninguna prueba unitaria envía avisos.

## Responsables de este bloque

- Coordinación principal: inventario, integración Git y estado compartido.
- `linux_state`: inventario de todas las ramas y pruebas transaccionales.
- `linux_transport`: catálogo compartido, empaquetado y revisión de CI Mac/Linux.
- `remote_inventory`: contraste de notas locales y límites de la evidencia.

Los estados históricos privados de cada equipo no sustituyen este resumen.
Al terminar un bloque, publicar el commit y actualizar solo su estado vigente.
