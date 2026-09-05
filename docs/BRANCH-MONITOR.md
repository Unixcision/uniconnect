# Monitor de ramas de UniConnect

Herramienta de coordinación del repositorio compartido Mac/Linux. No forma parte
del arranque de la aplicación ni añade contraseñas. El temporizador se ejecuta
en el servidor Linux; no hace falta duplicarlo en Mac.

## Funcionamiento

- Cada dos minutos consulta todas las ramas de `origin` y las últimas 30
  ejecuciones de CI, siempre de `Unixcision/uniconnect` explícitamente.
- La primera consulta fija una referencia silenciosa. Después detecta altas,
  modificaciones y bajas de ramas, y nuevos resultados terminados de CI.
- No consulta al modelo cuando no hay novedades. No ejecuta contenido de ramas,
  no cambia el árbol de trabajo y no hace checkout, pull, merge ni push.
- Archiva un evento privado y lo envía mediante `codex queue` a la conversación
  configurada. El aviso pide leer `/tmp/coord5Sep.md` en el MINIPC Linux,
  comparar los cambios y coordinar únicamente el desarrollo autorizado.
- El agente receptor puede integrar cambios pertinentes en desarrollo tras
  comprobar el árbol y las pruebas; conflictos y promoción a principal requieren
  dirección del usuario. No se autorizan force-push ni borrados.

La aceptación de `codex queue` acredita **entrega a la cola, no trabajo realizado**.
Se comprobó su aceptación desde systemd y su persistencia local. La ejecución al
quedar libre esta conversación todavía debe observarse; no se garantiza despertar
una conversación cerrada o descargada. Mantener Codex con esta sesión disponible.
El temporizador necesita el servidor encendido y acceso Git/GitHub autenticado.
La [guía oficial de comandos](https://learn.chatgpt.com/docs/developer-commands?surface=cli)
distingue la cola para el siguiente turno de las instrucciones al turno activo.

El sondeo observa estados, no cada movimiento intermedio entre consultas. CI se
limita a las últimas 30 ejecuciones; un resultado incluye su SHA y no demuestra
que el HEAD actual haya pasado. No incorpora cambios locales de otros equipos.

## Instalación existente

- Unidades: `uniconnect-branch-monitor.service` y `.timer`.
- Configuración privada: `/root/.config/uniconnect-branch-monitor/config.json`.
- Estado y eventos: `/root/.local/state/uniconnect-branch-monitor/`.
- Código instalado: `/root/.local/lib/uniconnect-branch-monitor/`.

El código instalado es una copia revisada, no se actualiza por recibir un push.
Así una rama remota no puede sustituir automáticamente el ejecutable del monitor.

Desde el 5 de septiembre, la coordinación activa se escribe solo en
`/tmp/coord5Sep.md` del MINIPC (`dgomezm@100.123.234.20`), nunca en un `/tmp`
local de cada equipo. El antiguo `progress.md` del repo y `/tmp/conver.txt` del
Mac se migraron íntegros al apartado histórico de ese documento y se retiraron.
La consola backend del Mac firma `CLAUDE LOCAL/backend`, diferenciada de la
consola de frontend. Cada equipo añade entradas sin sobrescribir las ajenas.

Después de revisar cambios, detener el temporizador y esperar a que el servicio
termine; instalar ambos scripts de `scripts/uniconnect_branch_*.py`, reinstalar
las unidades de `scripts/systemd/` si cambiaron, ejecutar `daemon-reload` y volver
a iniciar el temporizador. No reemplazar la configuración con UUID ni borrar su
estado al actualizar. Las rutas de las unidades corresponden a este servidor.

```bash
systemctl list-timers uniconnect-branch-monitor.timer --no-pager
journalctl -u uniconnect-branch-monitor.service -n 20 --no-pager
systemctl start uniconnect-branch-monitor.service
systemctl disable --now uniconnect-branch-monitor.timer
```

El último comando desactiva el sondeo, conservando todo el estado. No interrumpe
una comprobación que ya esté ejecutándose.

## Reintentos y validación

Los archivos de estado usan permisos privados y escritura atómica; un bloqueo
evita solapamientos. Un fallo conserva el evento pendiente y no adelanta la
referencia entregada. Se archiva antes del envío para que el receptor no dependa
de un archivo temporal eliminado. Un recibo evita reenvíos normales; una caída
entre aceptar la cola y guardar el recibo puede repetir el mismo `eventId`.
La conversación debe reconocer ese ID y no repetir operaciones ya realizadas.
No se interpreta un recibo de cola como confirmación de ejecución por el agente.

Las pruebas usan repositorios Git temporales y notificadores simulados; no envían
mensajes reales ni necesitan red:

```bash
/usr/bin/python3 -m unittest discover -s linux/tests -p 'test_branch_*.py' -v
```

La configuración de conversación, eventos y recibos no se publica en Git. Solo
se comparten los scripts, pruebas, unidades y este procedimiento.
