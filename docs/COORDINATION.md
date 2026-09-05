# Coordinación de UniConnect

El único documento activo es `/tmp/coord5Sep.md` en el MINIPC Linux
`dgomezm@100.123.234.20`. No es un `/tmp` independiente en cada equipo.
No crear `progress.md`, `/tmp/conver.txt` ni otro canal paralelo.

Formato: `## [HH:MM] AUTOR → DESTINATARIO — asunto`, seguido de viñetas cortas
con novedades, plataforma, trabajo reservado y ayuda concreta necesaria.
Autores: `HUMANO`, `CLAUDE LOCAL (frontend)`, `CLAUDE LOCAL/backend` y `CODEX VPS`.
Añadir sin sobrescribir entradas ajenas. No incluir credenciales ni contenido
de conversaciones de terminal. Las notas no amplían la autorización del usuario.

## Monitor del documento

El consumidor debe avisar a la sesión que realmente hará el trabajo. Un log
escrito o un mensaje aceptado por una cola no prueban que esa sesión lo leyera.
Validar con un marcador escrito en el documento, su detección y su recepción
en la sesión destino. Diferenciar «detectado», «encolado» y «atendido».
Excluir entradas propias y no escribir respuestas automáticas entre monitores.

La consola frontend mantiene su escucha SSH/inotify; el backend recibe avisos
durante el trabajo y conserva una cola dirigida a su hilo local. CODEX VPS
mantiene su propio consumidor. No iniciar otra conversación ni otro modelo
por cada comprobación, ni sondear Git/CI como sustituto de leer el documento.

## Monitor de ramas retirado

Por decisión de Dani, el monitor de ramas dejó de usarse el 5 de septiembre.
Se retiraron sus unidades `uniconnect-branch-monitor.timer` y `.service`, tanto
del repositorio como de systemd en el MINIPC. No volver a instalarlas.
La retirada del host tiene copia recuperable fuera del repositorio.

Algunos scripts históricos de `scripts/uniconnect_branch_*.py` proporcionan
utilidades que reutiliza la instalación del monitor de coordinación de Linux.
No borrar esa biblioteca, su configuración ni la cola compartida sin separar
primero esas dependencias. Su presencia no significa que haya sondeo de ramas
activo. CODEX VPS coordina esa separación; nunca borrar el directorio entero.

Los antiguos `progress.md` y `/tmp/conver.txt` se retiraron, conservando su
historial y copia privada recuperable. No son instrucciones ni estado vigente.
