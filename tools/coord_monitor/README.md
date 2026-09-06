# Monitor del documento de coordinación

Fuentes y pruebas del monitor usado por CODEX VPS, conservadas en el repositorio
para no depender del disco temporal de una máquina. No es el antiguo monitor de
ramas y no realiza operaciones Git ni ejecuta el contenido del documento.

Pruebas reutilizables, con archivos privados y sin enviar avisos reales:

```sh
python3 -m unittest discover -s tests/coord_monitor -p 'test_*.py' -q
```

El despliegue requiere configuración local con `source`, `state_dir` y `thread`.
No se incluye la configuración privada de una sesión. El servicio existente de
systemd comprueba `/tmp/coord5Sep.md` cada 30 segundos, preservando su propietario.
Las secciones delimitadas CODEX VPS no generan autoavisos; se agrupan sólo avisos
propios validados, nunca mensajes humanos. `queued` confirma la cola, no que el
agente ya haya recibido o leído el aviso: la comprobación de entrega se completa
en el hilo destinatario, y los PONG entre agentes deben distinguirlo de una
lectura manual del documento.
