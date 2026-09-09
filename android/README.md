# UniConnect para Android

Cliente nativo Kotlin + Jetpack Compose. Interfaz en español, sin WebView, sin
Stack Auth ni cuentas de terceros. Las máquinas se configuran explícitamente por
dirección Tailscale y puerto (58465 inicialmente).

## Estado real

- Splash nativo con el logo original de UniConnect.
- Rediseño 2026 (5 de septiembre): tema Material 3 Expressive (`MaterialExpressiveTheme`,
  `MotionScheme.expressive()`, `LoadingIndicator`), tarjetas de cristal, monogramas
  deterministas por caja como el rail compacto del Mac, riel horizontal de espacios de
  trabajo con sus ventanas debajo, hojas inferiores para alta de máquina y creación, y
  transiciones entre niveles. Componentes en `ui/components/`.
- Temas de diseño (9 de septiembre): cuatro temas elegibles en Ajustes → Apariencia,
  combinables con claro, oscuro o sistema. `domain/DesignTheme` (`SERENO`, `SENAL`,
  `TINTA`, `TERMINAL`) y `domain/ColorMode` se guardan en `AppSettings`; los valores
  antiguos siguen leyéndose y por defecto es Sereno + Sistema. `ui/theme/UniTokens.tokensFor`
  es una función pura que devuelve colores, formas, espaciado, tipografía y disposición
  de cada una de las ocho combinaciones; `UniTheme` las publica por `CompositionLocal`
  y deriva de ellas el `colorScheme`, las `Shapes` y la `Typography` de Material para que
  hojas, interruptores y botones hereden el tema. Ninguna pantalla lleva colores fijos:
  todo se lee de `UniTheme.colors` (acento, acento como tinte de contenedor, éxito, aviso,
  peligro, texto, atenuado, contorno translúcido y ocho tonos de monograma). Las paletas
  son las de las maquetas de diseño; los fondos son planos y las tarjetas un relleno con
  contorno de 1 px, sin degradados. Sereno: riel de fichas redondeadas y filas holgadas.
  Señal: filas compactas entre hairlines, cajas en rejilla de 2 columnas, etiquetas en
  versalitas con tracking. Tinta: titulares con serif, márgenes anchos, todo entre reglas
  y las cajas como lista índice. Terminal: identificadores en monoespaciada y cajas en
  rejilla densa de 3 columnas con contorno. El cambio se aplica al instante, sin reiniciar.
  Las barras del sistema siguen al modo.
- Creación en dos pasos: «Nuevo espacio de trabajo» envía `initial_terminal:false`; si el
  host confirma una caja vacía se abre al instante la hoja «Primera ventana de …» con el
  catálogo de inicio de esa caja. «Ahora no» deja la caja sin ventanas; nunca se lanza una
  terminal por defecto sin preguntar.
- Terminal: barra de teclas extra tipo Termux (ESC, CTRL/ALT pegajosos con bloqueo por
  pulsación larga, TAB, flechas, HOME/END, PgUp/PgDn, DEL, F1–F12 y símbolos) codificada
  por `domain/TerminalKeyEncoder` con secuencias xterm propias (sin código de Termux);
  modo «pantalla completa» donde arrastrar en vertical desplaza el scrollback del
  escritorio (`mobile.terminal.scroll`, coalescido y acotado) y modo ampliado con
  desplazamiento local; botón Reconectar (`mobile.terminal.reconnect`) que solo reataca la
  sesión durable existente. Si el árbol autorizado deja de contener la ventana abierta, la
  pantalla se cierra con aviso en vez de quedarse muerta.
- Favoritos y orden de espacios y ventanas: mantener pulsado abre una hoja con favorito,
  mover al principio, subir y bajar; la cabecera del espacio y la barra de la ventana
  abierta llevan la misma estrella. Los favoritos salen primero en su lista y el resto
  conserva el orden del host (`domain/BoxArrangement`). El host es la fuente de verdad:
  si `mobile.workspace.list` anuncia `capabilities: ["box_update"]`, el cambio va por
  `mobile.workspace.update` / `mobile.terminal.update` y se muestra la respuesta; si no
  la anuncia, no se llama al RPC y el móvil guarda el cambio por equipo
  (`data/StoredBoxOverridesRepository`) avisando una vez. Nada se deduce de códigos de
  error. Contrato completo en `docs/UNICONNECT.md` (apartado *Favourites and order*).
- Alta, validación, persistencia atómica y eliminación local de máquinas.
- Jerarquía nativa Máquinas → Espacios de trabajo → Ventanas alimentada por
  respuestas autorizadas; no presenta sesiones ni conexiones inventadas.
- Transporte TCP nativo cancelable, con mensajes UInt32BE + JSON UTF-8, límite de
  8 MiB, UTF-8 estricto, verificación del identificador RPC y plazos de conexión.
  Una lectura y una cola de escritura serializadas; eventos limitados a 64 mensajes
  y 8 MiB en total. El desbordamiento cierra el socket para recuperar estado completo.
- `NativeMachineClient` consulta los espacios y terminales reales mediante
  `mobile.workspace.list`. El servidor autoriza la IP Tailscale observada y puede
  responder `approval_required`; la app indica que debes aprobar el móvil en
  UniConnect, en la máquina. No hay contraseñas ni cuentas externas en Android.
- Lectura de pantalla completa `cmux.render-grid.v1` con lienzo Android nativo,
  colores y estilos básicos, y entrada explícita en la terminal seleccionada.
  Suscripción continua a eventos de pantalla, invalidaciones Linux y espacios de trabajo, con
  heartbeat de 15 segundos, espera progresiva de reconexión de 1 a 15 segundos
  y nuevo replay completo. Las revisiones visuales antiguas no revierten la pantalla.
  Los deltas compatibles sustituyen filas sin recolorear estilos de filas intactas.
  Si el host indica `is_ready:false`, el replay espera hasta 12 segundos al primer
  evento full de esa superficie, sin polling ni crear otra terminal. Agotado el
  plazo se ofrece reintento manual; no se confunde con un formato incompatible.
  Ajusta la escala de lectura al ancho del móvil y permite ampliarla con scroll
  horizontal, sin cambiar el tamaño de la terminal del escritorio. Faltan selección, ratón,
  historial remoto y soporte completo de atributos tipográficos/modos de terminal.
- Guardar una máquina **no** conecta al servidor, no ejecuta comandos y no crea
  terminales. Conectar, leer y enviar texto son acciones separadas. Un envío cuya
  entrega no se confirma se avisa y nunca se repite automáticamente.
- Creación explícita mediante formularios: caja local con carpeta absoluta o caja
  SSH heredada de otra; ventana local con carpeta opcional o SSH con nombre tmux.
  El inicio predeterminado es Terminal cuando el host lo anuncia. El selector usa
  el catálogo `available_agent_targets` de esa caja, incluidos los agentes propios
  del host, y envía el ID elegido sin comandos ni credenciales. SSH solo ofrece
  las opciones permitidas por el servidor. Un catálogo ausente o una opción retirada
  impide crear la ventana hasta elegir una opción vigente; nunca lanza otra IA por su cuenta.
  Las respuestas del servidor reconcilian el árbol sin inserciones optimistas.
- Avisos privados opcionales con conexión visible al ordenador, permiso contextual,
  deduplicación persistente y enlaces a la ventana original. Sin Google/FCM ni
  contenidos sensibles en la notificación. [Activación y límites reales](NOTIFICATIONS.md).

Las direcciones numéricas se limitan a `100.64.0.0/10` y
`fd7a:115c:a1e0::/48`. Se aceptan nombres MagicDNS; el transporte comprueba además
que resuelven a una IP Tailscale antes de conectar. No activa Tailscale, abre puertos
ni cambia la configuración de macOS/Linux por su cuenta.

## Enviar archivos

Sección global de la página principal (icono de nube en la barra superior y fila bajo las
máquinas) para subir fotos o archivos a un servicio de transferencia y copiar el enlace que
devuelve, pensada para pegarlo después en los servidores. No pasa por ninguna máquina de
UniConnect: el móvil habla directamente con el servicio.

- Tres entradas: «Hacer foto» (una app de cámara escribe en `cacheDir/photos` a través del
  `FileProvider` `${applicationId}.files`, `res/xml/file_paths.xml`), «Elegir imágenes»
  (selector de fotos del sistema) y «Elegir archivos» (documentos). Ninguna necesita permiso
  declarado: no hay `CAMERA` ni `READ_MEDIA_*` en el manifiesto; los selectores conceden
  acceso por URI y `TakePicture` no exige el permiso de cámara si la app no lo declara.
- Servicio configurable y persistido con los demás ajustes (`AppSettings.uploadService`,
  claves `settings.uploadDomain` y `settings.uploadStyle`), porque estos servicios caen.
  Presets medidos: `sendit.sh` (por defecto), `temp.sh`, `litterbox.catbox.moe` y
  `transfer.sh`; «Personalizado» admite un dominio propio con uno de tres estilos
  (`domain/UploadStyle`): `RAW_NAMED` (cuerpo crudo por POST a `/<nombre>`; sendit.sh y
  transfer.sh), `MULTIPART_FILE` (formulario con campo `file` a `/upload`; temp.sh) y
  `LITTERBOX` (`reqtype=fileupload`, `time=72h`, `fileToUpload`). El enlace es la primera
  URL http(s) del cuerpo, o las claves `link`, `url` o `downloadUrl` si es JSON
  (`domain/UploadLink`). Sin URL o HTTP ≥ 400 se muestra un error legible con el dominio.
- Transporte `data/HttpFileSender` con `HttpURLConnection`: sin dependencias nuevas,
  streaming con longitud fija (nada se carga entero en memoria), progreso por bytes,
  30 s de conexión y 10 min de lectura, `User-Agent: UniConnect Android`. Los archivos se
  suben en secuencia; un fallo se queda en pantalla con su motivo y botón Reintentar.
- Nombre saneado antes de enviarlo (`domain/UploadFileName`): sin directorios ni caracteres
  raros, acentos plegados, extensión conservada, nunca vacío.
- Historial de los últimos 30 enlaces en DataStore (`data/StoredUploadHistoryRepository`),
  con copiar, compartir y borrar. Copiar usa el portapapeles del sistema; compartir,
  `ACTION_SEND`.
- Pruebas: extracción del enlace en los tres formatos, saneado del nombre, URL por estilo,
  persistencia de servicio e historial, y `HttpFileSender` contra un servidor HTTP local en
  la JVM para los tres estilos, progreso, rechazo, respuesta sin enlace, host caído y
  archivo ilegible. No se ha probado contra los servicios reales desde la app.

### Adjuntar desde la terminal (file_put.v1)

En la barra de la ventana abierta (terminal real y espejo) hay un clip que abre una hoja
rápida «Adjuntar» con las mismas tres entradas. Si el host anuncia `file_put.v1` en
`capabilities`, el archivo viaja por la conexión privada móvil → host en trozos
(`mobile.file.begin/chunk/commit/abort`, trozos base64 de como mucho 1 MiB, SHA-256 al
cerrar; contrato completo en `docs/UNICONNECT.md`, apartado *File put*) y el host devuelve
la ruta donde lo ha dejado (o la ruta remota si ha podido copiarlo por scp a la caja SSH).
Esa ruta se pega al instante en la cajita del chat, con un espacio delante si ya había
texto y entre comillas si lleva espacios, y se avisa «Ruta pegada en la cajita», pero solo
si el archivo está donde corre el agente de la ventana: `remote_path` con `location=remote`,
o la ruta del host en una caja local. Si el salto SSH falla (`location=host` con
`remote_error`) en una ventana SSH, no se pega nada: la hoja muestra el fallo y ofrece
«Copiar ruta del equipo» (regla pura en `domain/AttachPaste.shouldPaste`). Si el host no
anuncia la capacidad, la hoja muestra sobre los tres botones una línea visible «<equipo>
no admite adjuntar directamente: se sube a <servicio> y se pega el enlace» y, al tocar
cualquiera, el archivo va al servicio de respaldo y se pega el enlace. Ese servicio se
elige en Ajustes → «Adjuntar desde la terminal» (igual que «Enviar archivos» por defecto,
un preset, o «Personalizado» con URL completa: esquema, host, puerto y ruta tal cual;
RAW_NAMED añade `/<nombre>` a esa ruta y los estilos de formulario envían a la URL tal
cual) y se guarda aparte (`terminalUploadService`) sin tocar la página. Un `not_found` en
chunk o commit (transferencia caducada, caja cambiada) es un fallo con su mensaje y
reintento desde el principio. Con tipo de caja desconocido tampoco se pega una copia del
host. La ruta (host o respaldo) y la ventana se capturan al tocar un botón en estado
restaurable (`domain/AttachCapture`, sobrevive a la muerte del proceso) y se resuelven al
volver del selector (`domain/AttachDecision`): si el equipo dejó de anunciar la capacidad
mientras tanto, el adjunto falla con su mensaje y nunca sale al respaldo por su cuenta; si
el resultado vuelve sin captura o para otra ventana, se descarta y se pide elegir de nuevo. `domain/FilePutTransfer` (puro) trocea, calcula el SHA-256 y aborta en el host si
algo falla; `data/NativeFilePutClient` habla el RPC sobre una sesión framed abierta para
toda la transferencia, con plazos de 60 s por trozo y 120 s para el commit (el scp puede
tardar). Los adjuntos van en secuencia y se quedan en la hoja con su motivo si fallan.
Probado en la JVM (troceado, sha256, índices, abort, pegado y cliente RPC contra una sesión
falsa); no probado contra un host real ni en el Pixel.

## Dictado por voz

En la cajita de la terminal, con el borrador vacío, el botón flotante de enviar es un micrófono
(«Dictar»); en cuanto hay texto vuelve a ser enviar, con transición. Al tocarlo se pide
`RECORD_AUDIO` en contexto (denegado: aviso breve; denegado para siempre: botón «Abrir
ajustes»). Grabando, el campo se sustituye por una barra con medidor de nivel (a partir de
`onRmsChanged`), el texto parcial en vivo, Cancelar (descarta) y Listo (para y usa lo dicho);
el botón flotante pasa a «Parar». Lo reconocido se AÑADE al borrador tras un espacio, nunca lo
pisa, y no se envía solo: en Ajustes → «Voz» está «Enviar al terminar de dictar» (apagado por
defecto; encendido manda con Intro como el botón) e «Idioma del dictado» («El del móvil»,
es-ES o en-US).

Motor: `android.speech.SpeechRecognizer` nativo sin dependencias, en `data/AndroidDictation`
(hilo principal). Prefiere el reconocedor local (`createOnDeviceSpeechRecognizer`,
`EXTRA_PREFER_OFFLINE`) cuando `isOnDeviceRecognitionAvailable` lo permite (Android 12+) y cae
al de red si el idioma no está disponible localmente; si no hay reconocimiento en el móvil el
micrófono no aparece. `domain/Dictation` es la interfaz (estado `Idle`, `Listening(parcial,
nivel)`, `Done(texto)`, `Failed(motivo)`), `domain/DictationMachine` la máquina de estados pura,
`DictationDraft.append` la regla de añadir y `ComposerAction.decide` la de micrófono/enviar; el
composable no sabe nada del reconocedor. Manifiesto: `RECORD_AUDIO` y `<queries>` del
`RecognitionService`. Probado solo en la JVM (máquina de estados, añadir al borrador, decisión
del botón, persistencia de los ajustes); el reconocimiento real no se ha ejercitado en el Pixel.

## Arquitectura

El usuario asume el diseño y frontend Android desde el 5 de septiembre de 2026.
Los siguientes cambios de esta consola se limitan a backend, sesiones y despliegue;
coordinar cualquier modificación de `ui/` antes de editar esos archivos.

El compositor publicado en `9f8365fc9` envía el texto y `Intro` en una única
petición explícita. `MachinesViewModel.sendInput(text, onDelivered)` confirma
aceptación inmediata o en cola por el host, no que el comando haya terminado.
Solo esa confirmación borra el borrador; una entrega incierta conserva el texto
y nunca se reintenta automáticamente. Las teclas y «Solo texto» siguen siendo
acciones separadas. La vista de chat real aún no tiene API implementada: una
cuadrícula del terminal no debe transformarse en mensajes de IA inventados.

`domain/` contiene valores e interfaces. `data/` implementa persistencia y
transporte. `ui/` recibe instantáneas y acciones de un ViewModel. `AppContainer`
compone e inyecta las dependencias en el arranque; las filas no conocen servicios.
Las direcciones se guardan en DataStore privado y la copia de seguridad Android
está desactivada. No se guardan contraseñas en estos registros.

## Compilar sin instalar

Requiere JDK 17 o compatible, Android SDK 36 y conexión a los repositorios de
dependencias. El wrapper fija Gradle 8.14.3; AGP 8.13.1 y Kotlin 2.2.20 están
fijados en el proyecto. Compose usa el BOM `2026.06.01` (el último compatible con
`compileSdk 36` y AGP 8.13) y Material 3 `1.5.0-alpha18`, fijado aparte porque la línea
estable 1.4 no incluye los componentes expresivos; las alphas posteriores exigen SDK 37
y AGP 9.1. No requiere abrir Android Studio.

```sh
cd android
ANDROID_HOME=/ruta/al/Android/sdk ./gradlew :app:assembleDebug --no-daemon --max-workers 2
```

APK: `app/build/outputs/apk/debug/app-debug.apk`. No se instala automáticamente.
Gradle usa como máximo dos trabajadores y 1536 MiB de heap. El logo se copia durante
la compilación desde `../design/UniConnect.icon/Assets/uniconnect-icon.png`; no hay
una segunda versión del arte que mantener.

No ejecutar tests locales según el contrato del repositorio. Para CI/VM:
`./gradlew :app:testDebugUnitTest`. Las pruebas de validación ejercitan direcciones
aceptadas/rechazadas, puertos, formularios de creación, reemplazo de pantalla,
deltas de filas/estilos y revisiones antiguas, sin red ni datos del usuario.
También diferencian plazo de red y cancelación del propietario para que un timeout
no deje estados de conexión o envío bloqueados.
También cubren entregas de avisos y confirmación de input inmediato o en cola:
`queued:false` en una respuesta correcta significa enviado, no rechazado.
Compilar sin ejecutarlas: `./gradlew :app:compileDebugUnitTestKotlin`.

## Referencias oficiales

- [Compatibilidad de AGP 8.13](https://developer.android.com/build/releases/agp-8-13-0-release-notes).
- [Plugin del compilador Compose](https://developer.android.com/develop/ui/compose/setup-compose-dependencies-and-compiler).
- [SplashScreen nativo](https://developer.android.com/develop/ui/views/launch/splash-screen/migrate).

La instalación y revisión visual en el Pixel han sido autorizadas por el usuario.
Se verificaron aprobación en la UI del Mac Debug, listado real, pantalla en directo
y envío de un eco inocuo desde los botones del Pixel, sin modificar producción.
Las notificaciones en reposo y la equivalencia Linux requieren sus propias pruebas;
la compilación por sí sola no demuestra esos comportamientos.
