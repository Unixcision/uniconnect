# Recuperación y copias de seguridad de UniConnect

UniConnect trata cada caja y todas las ventanas que contiene como estado
duradero. Cerrar una ventana, salir de un agente, perder la red o cerrar la
aplicación no debe borrar la información necesaria para reconstruirlo.

## Qué se conserva

Para cada ventana local, la instantánea de sesión legible conserva:

- los identificadores de caja y panel, los nombres visibles, el color, el orden y la selección;
- la carpeta predeterminada del espacio de trabajo y el directorio de trabajo local
  elegido de forma independiente para cada ventana, que puede estar fuera de esa
  carpeta predeterminada;
- si el entorno de ejecución es un shell de inicio de sesión, un agente o una terminal detenida;
- los registros de conversación de Claude, Codex, Agy y Grok, a los que solo se
  añaden entradas, incluidos el tipo de agente, el ID de sesión nativo detectado,
  la carpeta de reanudación específica de cada conversación y las marcas de tiempo;
- únicamente el nombre reconstruido de un ejecutable de confianza y su opción de
  permisos obligatoria. Los argumentos argv capturados, las claves de API y las
  variables de entorno capturadas se eliminan antes de guardar.

Para cada ventana SSH conserva:

- los identificadores de caja y panel, los nombres, el color, el orden y la selección;
- un UUID de credencial opaco;
- el nombre exacto de tmux guardado y los metadatos de la ventana;
- la referencia de conexión y el estado de desconexión que necesita la interfaz.

El propio comando SSH —incluida una contraseña de `sshpass` o la ubicación de
una clave privada— existe solo dentro de la bóveda cifrada. Nunca se copia en
el JSON de sesión legible, el historial de cierres recientes, la vista previa,
el diario ni los registros.

## Cuándo se guarda

`UniConnectSessionPersistenceObserver` solicita un guardado tras cada
modificación del modelo relevante para la recuperación: pertenencia y orden de
cajas, grupos, selección, nombres, color, fijación, carpeta, pertenencia,
disposición y orden de paneles, perfil, referencia de credencial, vinculación
de tmux, historial del agente local y estado de ejecución o de conexión. Las
solicitudes de una misma transacción del bucle principal de eventos se agrupan
para que la instantánea guardada sea coherente.

Un autoguardado independiente se ejecuta cada ocho segundos. Las huellas
idénticas pueden evitar brevemente escrituras redundantes, pero se fuerza un
guardado al menos una vez por minuto. Las escrituras usan un archivo temporal
privado, `fsync`, un renombrado atómico y un `fsync` del directorio; los
directorios tienen modo `0700` y los archivos modo `0600`.

## Historial rotatorio de copias

Tras un guardado de sesión correcto, `UniConnectRecoveryBackupRepository` crea
un punto de recuperación programado cuando han transcurrido seis horas desde el
anterior:

```text
~/.uniconnect/backups/
├── session-<milliseconds>-scheduled-<uuid>.json
└── session-<milliseconds>-scheduled-<uuid>.vault.uc
```

Eso supone cuatro oportunidades de recuperación al día mientras la aplicación
está en ejecución y puede guardar. Las entradas con más de siete días se
eliminan y el historial se limita a 28 entradas. El `.json` contiene,
deliberadamente, estado de trabajo local legible; el `.vault.uc`
correspondiente, cuando existe, permanece cifrado. Las compilaciones Debug usan
un directorio aislado `~/.uniconnect/debug/<bundle-id>/backups/` y no pueden
utilizar accidentalmente el historial de Release.

Antes de aplicar una instantánea de recuperación, el estado actual se archiva
con el motivo `before-restore`. Esto también permite revertir una restauración
equivocada.

## Restaurar un punto automático

Usa **Archivo → Restaurar copia de seguridad…** y elige un JSON del historial
propio de UniConnect. El selector rechaza archivos fuera de ese directorio,
enlaces simbólicos, JSON dañados e instantáneas no compatibles. Tras confirmar:

1. UniConnect archiva el estado actual.
2. Las credenciales que faltan se incorporan desde la bóveda cifrada asociada;
   nunca se sobrescribe silenciosamente una credencial actual existente.
3. Las cajas y ventanas recuperadas se abren junto a las actuales.
4. Las asignaciones de propiedad de las sesiones locales se concilian para que
   una sesión nativa de agente tenga como máximo un propietario activo.
5. Una ventana SSH comprueba el nombre exacto de tmux guardado y se conecta a
   esa sesión. Si ha desaparecido, la reconstrucción de la instantánea vuelve a
   crear el mismo nombre y se conecta sin desconectar a otro cliente. Un shell
   recreado no es una conversación de IA reanudada.

Si falta una carpeta local obligatoria, no se lanza un agente en un directorio
no previsto. Los enlaces a las conversaciones guardadas siguen disponibles, y
elegir una carpeta de sustitución para una ventana no debe modificar otras
ventanas ni la carpeta predeterminada del espacio de trabajo. Cada conversación
conserva su propia carpeta de reanudación. Las importaciones explícitas
limitadas a sesiones existentes siguen requiriendo que su comprobación previa
remota encuentre el tmux guardado; las sesiones ausentes no superan esa
comprobación. La recuperación nunca omite esta comprobación previa. Una sesión
que desaparece después de una validación correcta puede recrearse durante una
reconstrucción posterior de la instantánea.

## Copia de seguridad manual y exportación portátil

Cada ventana local guarda su nombre y una carpeta de trabajo independiente.
Elegir una carpeta fuera de la predeterminada del espacio de trabajo no modifica
otras ventanas ni la configuración predeterminada. Cada conversación conserva
su propia carpeta de reanudación.

**Guardar ahora** (`⌘S`) solicita un nuevo análisis asíncrono de los agentes
locales compatibles antes de forzar y confirmar la escritura de la sesión
activa en disco. La detección se intenta con la información disponible: una
conversación solo se puede reanudar cuando la integración compatible permite
obtener su ID de sesión nativo real. UniConnect nunca inventa un ID, lo deduce
del nombre de una ventana ni descarta conversaciones guardadas previamente
cuando un análisis no encuentra nada. El nombre de la ventana y la carpeta
local siguen guardados aunque no se detecte ninguna sesión de IA reanudable,
incluidos los shells ordinarios y los comandos puntuales.

Tras confirmar la escritura de la sesión, escribe el `backup.json` legible y
sin secretos junto con su archivo asociado de credenciales cifrado y
autenticado, además de un historial acotado de pares correspondientes. El JSON
solo se confirma después de que su archivo de bóveda asociado, con nombre
único, esté guardado de forma duradera, para que un fallo no combine el estado
de una generación con las credenciales de otra. Los archivos heredados
`backup.uc`, que contienen el documento completo, se leen y migran sin
eliminar el original que permite revertir la operación. Un fallo al escribir la
sesión activa se notifica como error, nunca como **Guardado** ni como una copia
de seguridad completa confirmada. Esto resulta útil antes de un cambio manual
importante.

Las exportaciones portátiles y los puntos de control temporales de importación
siguen siendo documentos cifrados íntegramente de forma deliberada. Una
exportación portátil es un archivo de transporte protegido por una frase de
contraseña; un punto de control de importación es una unidad interna de
reversión atómica que debe restaurar el documento, la instantánea de sesión
exacta y la revisión exacta de la bóveda como una sola unidad autenticada.
Ninguno de los dos es un archivo de configuración activo o legible.

**Exportar configuración…** crea un contenedor portátil `.uniconnect`
protegido por una frase de contraseña del usuario (PBKDF2-HMAC-SHA256 más
AES-256-GCM). A diferencia del JSON automático legible, el contenido exportado
puede incluir datos de conexión porque todo el contenido está autenticado y
cifrado. Las frases de contraseña incorrectas, los archivos truncados y la
manipulación de su contenido se rechazan antes de modificar el estado.

La recuperación automática, **Guardar ahora** y la exportación portátil se
complementan:

| Mecanismo | Propósito | Tratamiento de secretos |
|---|---|---|
| Instantánea activa | Reconstrucción exacta en el siguiente inicio | Estado legible; solo identificadores de credencial opacos |
| Historial de seis horas | Recuperar borrados accidentales o corrupción durante siete días | Estado legible más copia cifrada separada de la bóveda |
| Guardar ahora | Punto de control local solicitado por el usuario | Estado legible más archivo de bóveda cifrado asociado a la misma generación |
| Exportación portátil | Transferencia o recuperación ante desastres sin conexión | Contenedor cifrado autenticado mediante una frase de contraseña |

## Lista de comprobación para la recuperación operativa

Si una conexión se queda bloqueada tras cambiar de red, usa **Volver a conectar
ahora esta ventana SSH** (`⌘R`) para la ventana SSH/tmux seleccionada, o
`⌃⌘R` para todas las ventanas SSH que correspondan. UniConnect termina
únicamente su grupo local de procesos SSH y reconstruye cada panel con el mismo
tmux guardado; conserva los paneles y los nombres de tmux, no espera al tiempo
de espera habitual de SSH y nunca envía `tmux kill-*`.

El inicio normal, la reconstrucción de instantáneas guardadas —incluidas la
recuperación desde el historial de copias y la reapertura desde el historial de
cierres—, la reconexión y el reinicio por cambio de revisión de credenciales se
conectan al nombre exacto de tmux guardado cuando existe, o recrean
automáticamente ese mismo nombre cuando no existe. Nunca desconectan a otro
cliente. Las comprobaciones previas de las importaciones explícitas limitadas a
sesiones existentes siguen siendo estrictas: la comprobación previa remota de
existencia es obligatoria y no crea una sesión de sustitución durante la
validación. Si la sesión desaparece después de superar esa comprobación, puede
recrearse en una reconstrucción posterior de la instantánea.

Un tmux recreado restaura un shell, no un proceso de IA terminado ni su
conversación. Una conversación de IA solo puede reanudarse a partir de su ID
nativo canónico guardado y de su carpeta de reanudación registrada; UniConnect
nunca los sustituye por `--continue` ni adivina la conversación más reciente.
La ausencia de identidad no debe notificarse como una sesión de IA recuperada.

Si un agente local termina, permanece en el shell y usa el menú de acciones de
la ventana para reanudar una conversación registrada o iniciar otro agente. No
elimines la conversación salvo que confirmes explícitamente **Olvidar la
conversación guardada**.

Si falla una actualización firmada, el instalador conserva la aplicación
anterior en `~/.uniconnect/backups/install/<timestamp>/UniConnect.app`.
Restaurar ese paquete también restaura su identidad estable de firma de código;
no elimines la copia de seguridad hasta haber comprobado manualmente la
aplicación actualizada.

Nunca repares una bóveda sobrescribiéndola con un archivo vacío. Conserva el
JSON de sesión actual, la bóveda y la copia de seguridad de instalación, y
después restaura la última aplicación firmada que sepas que funciona o importa
una exportación portátil verificada.
