# Base Android — estado de implementación

Actualizado: 2026-09-10. Responsable: agente `bridge_lifecycle_audit`; última entrada, el agente Android de Whisper local.

## Ya creado

- Proyecto nativo Kotlin + Jetpack Compose, sin WebView ni cuentas externas.
- AGP 8.13.1, Kotlin 2.2.20, Gradle 8.14.3; SDK 36, mínimo 26, JVM 17.
- Límite de compilación: dos trabajadores, memoria de Gradle de 1536 MiB.
- Splash nativo AndroidX, tema oscuro y reutilización automática del PNG canónico
  `design/UniConnect.icon/Assets/uniconnect-icon.png` sin duplicarlo en fuentes.
- Recursos de interfaz solo en español y manifiesto sin copia de seguridad.
- Sistema de temas (2026-09-09): cinco temas de diseño × claro/oscuro/sistema en
  `ui/theme/` con tokens puros y testeados (`UniTokensTest`: contraste WCAG de texto,
  atenuado, acento y estados en las diez combinaciones; serif en Tinta, mono en Terminal,
  Señal compacto). La paleta fija `Brand` ha desaparecido. Persistencia cubierta por
  `StoredSettingsRepositoryTest` con un DataStore en memoria. Verificado solo compilando y
  con tests: no se ha instalado en ningún móvil ni revisado visualmente.
- Tema Nieve (2026-09-09): quinto tema minimalista y flotante, primero de la lista en
  Ajustes → Apariencia. Token nuevo `ui/theme/UniElevation` (capa ambiente, capa corta,
  elevación por color para el modo oscuro y grosor del canto) como sexto campo de
  `UniTokens`; los otros cuatro temas usan `UniElevation.flat` y no cambian de aspecto.
  `UniType` gana `labelQuiet` y `UniShapes` gana `fieldRadius` (por defecto el de los
  botones, así que solo Nieve lo separa). `GlassCard` apila dos `Modifier.shadow` cuando
  el tema flota y mantiene el canto en 0,5 dp; en oscuro pone un 5 % de blanco sobre el
  relleno. La fila de fichas de tema pasa a scroll horizontal con fichas de 96 dp porque
  cinco no caben repartidas, y la miniatura dibuja la sombra o la elevación del tema que
  representa. `extraSmall` de Material se acota al radio de tarjeta para que un chip
  píldora no convierta los menús desplegables en lozanges. Tests: `UniTokensTest` (18
  casos, incluidos contraste WCAG de Nieve en claro y oscuro, densidad COMFORTABLE,
  radios grandes, píldoras, aire, sombra en claro / elevación en oscuro, canto por debajo
  del píxel y etiquetas quietas) y `UniElevationTest` (3 casos). 221 tests JVM en verde.
  No se ha revisado visualmente en ningún móvil ni emulador.
- Enviar archivos (2026-09-09): sección global en la home (icono en la barra y fila bajo
  las máquinas) que sube fotos, imágenes o archivos a un servicio de transferencia y da el
  enlace para copiar o compartir. Servicio elegible y guardado en ajustes (presets
  sendit.sh, temp.sh, litterbox.catbox.moe, transfer.sh, o dominio propio con estilo
  RAW_NAMED / MULTIPART_FILE / LITTERBOX), historial de 30 enlaces, subida secuencial con
  progreso y reintento. Sin permisos nuevos: FileProvider para la foto, selectores del
  sistema para el resto. Protocolos según lo medido el 9 de septiembre. Tests JVM incluido
  `HttpFileSender` contra un `HttpServer` local; no probado contra los servicios reales ni
  instalado en el Pixel.
- Dictado por voz (2026-09-09): micrófono en el botón flotante con el borrador vacío,
  SpeechRecognizer nativo (local preferido, red de respaldo), permiso en contexto, barra de
  dictado con nivel y texto parcial, añadido al borrador con espacio, ajustes «Voz» (enviar al
  terminar, idioma). Máquina de estados pura y reglas testeadas en JVM; sin probar en el Pixel.
- Adjuntar desde la terminal (2026-09-09, contrato `file_put.v1`): clip en la barra de la
  ventana abierta, hoja rápida con foto/imágenes/archivos, transferencia por trozos base64
  ≤ 1 MiB con SHA-256 por la sesión RPC, ruta (remota si el host la da) pegada al instante
  en la cajita solo si está donde corre el agente (remota en SSH, host en local; si el salto
  SSH falla se muestra y se ofrece copiar, no se pega). Sin capacidad: línea visible sobre
  los tres botones y subida directa al servicio de respaldo de Ajustes → «Adjuntar desde la
  terminal» (por defecto el de «Enviar archivos»; Personalizado admite URL completa).
  Tests JVM de troceado, pegado y cliente RPC contra una sesión falsa. Mac y Linux aún no
  implementan el host; no probado contra ninguno ni en el Pixel.

- Whisper en el propio móvil (2026-09-10): tercer motor de transcripción, sin conexión.
  whisper.cpp vendorizado y podado en `app/src/main/cpp/whisper/` (solo backend de CPU de ggml,
  6,1 MB de fuentes; commit en `whisper-commit.txt`, licencia MIT incluida) con JNI propio
  `uniwhisper.cpp` (progreso y cancelación reales vía `progress_callback`/`abort_callback`).
  CMake 3.22.1 + NDK 28.2.13676358, `abiFilters` solo `arm64-v8a`,
  `-march=armv8.2-a+fp16+dotprod`; `data/WhisperNative` comprueba `asimdhp`/`asimddp` en
  `/proc/cpuinfo` antes de cargar la librería. **APK Debug 24,12 MB → 26,71 MB (+2,59 MB de
  `libuniwhisper.so`, que va sin comprimir); el APK ya solo trae arm64-v8a.** El modelo NO va en el
  APK: `data/HttpSpeechModelStore` descarga `ggml-base-q5_1.bin` (56,9 MB) o `ggml-small-q5_1.bin`
  (181 MB) a `filesDir/whisper/` con reanudación por `Range`, comprobación de espacio libre,
  verificación de tamaño exacto y de la magia `ggml`, y borrado. `domain/LocalDictation` graba con el
  mismo `MediaRecorderVoice` que para un equipo, decodifica con `data/MediaCodecAudioDecoder`
  (`MediaExtractor` + `MediaCodec` sobre un `MediaDataSource` en memoria) y `domain/PcmSamples`, y
  lee el modelo en `Dispatchers.Default` con porcentaje y cancelación. Si el motor falla,
  `domain/ClipHandover` pasa la grabación a `HostDictation.adopt` en vez de perderla.
  Ajustes → «Voz» → «Transcripción» pasa a cuatro filas con radio y frase explicativa: Automática,
  Un equipo concreto, Whisper en el móvil, Reconocedor del móvil; el valor antiguo `HOST`
  («Ventana») desaparece y se lee como `AUTO`. Nueva sección «Modelo de voz en el móvil» con estado,
  progreso, tamaño en disco y borrado, y la última medida real de tiempo. La barra de dictado dice
  quién transcribe salvo cuando es el equipo de la ventana. 318 pruebas JVM en verde, entre ellas
  `TranscriptionRouteLocalTest` (todas las combinaciones más el invariante de que nunca se enruta a
  un motor que no puede correr), `PcmSamplesTest`, `LocalDictationTest`, `HttpSpeechModelStoreTest`
  (servidor local con rangos y cortes), `SpeechModelTest` y `ByteSizeTest`. **No probado en ningún
  móvil: no se ha medido cuánto tarda de verdad ni se ha instalado el APK.**

## En curso

- Ya implementados: modelos, repositorio DataStore y formulario Tailscale.
- Ya implementada: navegación Máquinas → Espacios → Ventanas con DTO reales.
- Ya implementado: TCP UInt32BE + JSON, máximo 8 MiB, cancelación y plazos.
- Autorización por IP observada aprobada EN UniConnect, sin Stack Auth/OAuth ni
  secretos Android. El agente principal integra el listener real Mac/Linux.
- Sesión TCP persistente, RPC correlacionadas, cola de eventos limitada a 64
  mensajes / 8 MiB, UTF-8 estricto y cierre ante desbordamiento.
- Suscripción continua a workspace.updated / terminal.render_grid; full replay
  inicial, barrera de recepción, descarte de revisiones antiguas y deltas por fila.
- Reconexión con espera progresiva de 1 a 15 s y nueva pantalla completa, sin
  reenviar entrada incierta. Una entrada pendiente como máximo, hasta 256 KiB.
- Canvas nativo con colores, cursor, negrita/cursiva/subrayado y estilos por span
  congelados para no recolorear filas ajenas al recibir deltas.
- Formularios explícitos de creación ya compilados: cajas local/SSH heredada,
  ventanas local/SSH con tmux exacto; inicio Terminal, sin IDs de IA inventados.
  No crear ni reiniciar sesiones al abrir/reconectar. Ninguna creación real aún.

## Contrato acordado

- Puerto inicial: 58465.
- Destinos: IPv4 `100.64.0.0/10`, IPv6 `fd7a:115c:a1e0::/48`, MagicDNS.
- No abrir direcciones públicas/LAN ni cambiar servicios de la máquina sin acción.
- No afirmar conexión ni mostrar espacios inventados si no hay autorización.
- Favoritos y orden (2026-09-08, cerrado en el canal de coordinación con CODEX VPS):
  el host anuncia `capabilities: ["box_update"]` en `mobile.workspace.list` cuando
  implementa `mobile.workspace.update {workspace_id, is_pinned?, position?}` y
  `mobile.terminal.update {workspace_id, terminal_id, is_pinned?, position?}`.
  Valores explícitos por ID (nunca toggle), sin tocar foco, selección ni splits;
  primero `is_pinned`, después `position` base cero dentro de su grupo
  (fijados / no fijados), fuera de rango se recorta; respuesta = el mismo objeto que
  `workspace.list`. Android ya lo implementa (commits b32bd0cf9 y e3e96078c); Mac y
  Linux pendientes. "Sincronizar" = el host comparte con todos sus clientes; Mac y
  Linux son instalaciones distintas, no se fusionan.

## Validación pendiente

- Whisper local: falta instalar en el Pixel 8 Pro y medir de verdad `base` y `small` con audio
  español real, y ver cuánto calienta. La app ya lo mide y lo enseña en Ajustes; sin ese dato no se
  puede decir si `small` sirve para dictar o solo para tener paciencia.

- Wrapper y APK Debug compilados; compilan también las pruebas unitarias, sin
  ejecutarlas. `assembleDebug compileDebugUnitTestKotlin`: éxito en 18 segundos.
- El usuario YA ha autorizado instalar/validar en Pixel por ADB Tailscale.
  APK instalada correctamente en Pixel 8 Pro (Android 17) y app abierta.
- Revisión visual detectó color heredado negro en algunos títulos; corregido
  con LocalContentColor de tema. Reinstalación y captura home-fixed.png verifican
  contraste correcto; formulario revisado en Pixel. Copy de nota de seguridad
  actualizado a «Solo tus máquinas. Conexión privada mediante Tailscale.».
- APK con streaming y pruebas de reducer/endpoint compiladas de nuevo en 18 s,
  reinstalada en Pixel. Las pruebas NO se han ejecutado localmente.
- Última compilación conjunta APK + fuentes de tests: éxito en 14 s. Veinte pruebas
  de comportamiento escritas, compiladas sin ejecución local.
  Auditoría XML: 99 recursos de producto en español, 99 claves
  usadas, ninguna referencia ausente; singular/plural de ventanas correcto.
- Conexión de pantalla se pausa al pasar la app a segundo plano y hace replay al
  volver; la entrada pendiente no se repite automáticamente.
- Revisión independiente corrigió cuatro hallazgos antes de la prueba real:
  deadline propio no se confunde con cancelación del usuario; select de heartbeat
  no pierde un evento; una creación completada en segundo plano no reabre streaming;
  un protocolo incompatible no causa reconexiones infinitas ni reinicia el backoff.
  Errores tipados compartidos en domain/, sin importar el transporte desde UI.
- Capturas privadas: `/private/tmp/uniconnect-android-visual.9gD4ut/`.
- Máquina real guardada desde el formulario en Pixel; primera conexión con el
  listener del Mac apagado rechazada y mostrada como error/reintento, sin inventar
  árbol ni estado online. Después se verificó `approval_required` y se autorizó
  exactamente la IP del Pixel en la UI «Acceso remoto» del Mac Debug aislado.
- E2E real: listado, pantalla de la terminal existente y eco desde el campo/botones
  Android. La primera prueba detectó interpretación errónea de `queued:false`:
  significa envío inmediato, no fallo. Corregido y vuelto a probar sin aviso falso.
  Evidencia: `pixel-echo-ack-fixed.png` en la carpeta privada de capturas.
- Veinte pruebas de comportamiento compiladas, sin ejecución local. Nuevas:
  deduplicación de avisos, confirmaciones de input inmediato/en cola y fixture JSON
  real compartida con Linux (celdas anchas, color, inversión, cursor y revisión).
- Avisos privados implementados y compilados: servicio visible opt-in, permiso
  contextual, registro de IDs, enlace a destino exacto y límites documentados en
  NOTIFICATIONS.md. Verificados en Pixel: permiso contextual, servicio visible,
  entrega real en primer plano y tras Home, deduplicación tras desactivar/reactivar,
  tap que abre la ventana exacta. No se marca leído el aviso del host. No se ha
  forzado Doze ni cambiado la VPN; no se ha medido entrega con pantalla apagada.
- Ajuste de lectura al ancho disponible, sin modificar la geometría del Mac;
  botón para ampliar y desplazar horizontalmente. Linux invalida con
  terminal.updated; el cliente agrupa una tanda acotada y pide un único replay.
- No se ha abierto ningún emulador ni cambiado configuración del Mac desde Android.
- No se han hecho commits ni cambios fuera de `android/`.

- Favoritos y orden validados en el Pixel 8 Pro contra el MINIPC Linux (sin capacidad,
  ruta local): marcar un espacio lo pone primero con estrella y aviso ámbar, quitarlo
  lo devuelve a su sitio, la ventana se marca desde la lista y desde la barra abierta,
  y todo sobrevive a matar el proceso. Corregido en la misma tanda: la fila perezosa
  anclaba el scroll a la primera ficha y escondía el favorito que saltaba al principio.
  Repetido el 2026-09-09 contra el Linux del MINIPC con `box_update` (f33dc23cc7): sin aviso,
  traspaso inicial de los favoritos locales al host, pin/unpin/bajar/mover al principio por RPC
  y el móvil pinta el snapshot del host. Quitar el favorito deja el elemento donde está en la
  lista del host (no vuelve a su sitio anterior): comportamiento esperado.

## Riesgos de contrato comunicados al agente principal

- Los eventos full del host llevan `revision`, pero replay debe llevar una revisión
  de la misma fuente o asegurar una captura full posterior para resolver de manera
  exacta cualquier cruce entre respuesta de replay y eventos ya encolados.
- El transporte valida IP/DNS de tailnet; sigue pendiente decidir y comprobar
  requisito de VPN activa/ruta local tailnet antes de abrir el socket. Un prefijo
  CGNAT por sí solo no identifica criptográficamente al proveedor de VPN.
- E2E Mac de aprobación, árbol, pantalla, input y avisos ya demostrado. Faltan
  interrupción de red, revocación, reposo profundo y prueba real Linux. No confundir esos
  pendientes con la prueba de eco que sí se ha realizado.

## Dictado con Whisper del equipo (9 de septiembre de 2026)

- Implementado el lado móvil de `transcribe.v1`: grabación MPEG-4/AAC 16 kHz mono a 32 kbps en
  `cacheDir`, envío en una sola llamada `mobile.audio.transcribe` con 90 s de plazo, texto añadido
  al borrador y audio borrado en todos los caminos (éxito, rechazo, cancelación y arranque nuevo).
- La elección de motor es pura y comprobable: `TranscriptionRoute.decide(modo, capacidad del equipo,
  hay reconocedor)`. Sin capacidad o con `unsupported` se dicta en el móvil, avisando una sola vez.
- Ajustes → Voz → «Transcripción»: Automática (por defecto), Móvil y Equipo.
- Límite del contrato corregido a 3 MiB de audio (aviso de CODEX VPS): 6 MiB en base64 son 8 MiB
  clavados, la trama entera, así que la petición reventaba antes de llegar al host y sin poder
  responder `too_large`. El móvil mide antes de enviar y comprueba también la petición serializada.
- `busy` mapeado como espera, no como error desconocido (el host Linux ya lo devuelve: un dictado por
  dispositivo, dos por equipo). La grabación se conserva para todos los reintentos que hagan falta y
  solo se borra al acertar o al descartar el aviso.
- El dictado ya puede usar OTRO equipo distinto al de la ventana (medido: el Mac tarda 1,8 s donde el
  MINIPC tarda 68 s y entiende mal). Automática usa el de la ventana, si no el primero conectado que
  pueda, si no el móvil; Ajustes gana «Elegido» con la lista de máquinas y guarda el identificador.
- Cuando transcribe otro equipo, la petición no lleva `workspace_id` ni `terminal_id` y la barra dice
  qué equipo lo hace. El `unsupported` se recuerda por máquina, no en general.
- Una grabación ya no se pierde porque el equipo no pueda: `unsupported` y una caída de red la
  reencaminan en el acto al siguiente equipo capaz, sin que el usuario toque nada.
- Al agotar destinos el aviso describe la ruta real: si alguno solo se quedó sin contestar, el audio
  se conserva y se ofrece reintentar contra ESE equipo; solo si ninguno tiene motor se descarta,
  explicándolo, y «Dictar otra vez» fuerza el dictado local en vez de volver a la regla automática.
  Sin reconocedor en el móvil no se promete dictado local ni se ofrece botón.
- 54 pruebas JVM nuevas (elección de motor, base64 por bloques, tope de 3 MiB y trama, cada código de
  error del contrato contra un host de mentira en un par de sockets, borrado del archivo en todos los
  caminos, reintento único, corte a los 5 minutos, persistencia del ajuste). Build y
  `testDebugUnitTest` en verde.
- No probado contra un host real: ningún equipo anuncia todavía `transcribe.v1`, así que el camino
  del móvil es el único ejercitado de punta a punta. Tampoco se ha instalado nada en el Pixel.

## Dictado local arreglado en el Pixel (10 de septiembre de 2026)

- Diagnóstico real en el Pixel 8 Pro (Android 16, es-ES, permiso concedido): al tocar el micrófono
  el audio entraba, pero el reconocedor local abortaba al instante y salía «No se ha entendido» sin
  que la barra llegara a verse. El servicio por defecto es `com.google.android.tts`, que no tiene
  modelo de español para `createOnDeviceSpeechRecognizer`.
- Un error sin parciales y en menos de 1,5 s ya no se trata como «no se ha entendido»: se reintenta
  una vez con el reconocedor de red, en silencio, manteniendo la barra. Si ese también se rinde
  igual de rápido, el aviso lo dice y ofrece usar el equipo si alguno puede transcribir.
- La barra se publica al tocar el micrófono, antes de la primera llamada del motor.
- Extras de silencio (1,5 s / 1,5 s) y mínimo (2 s) en el intent, y `EXTRA_LANGUAGE` con la etiqueta
  del sistema cuando el ajuste es «El del móvil»; nunca una etiqueta vacía.
- Cada intento lleva número (`domain/DictationAttempts`): cancelar entre el fallo de un motor y su
  reintento encolado ya no reabre el micrófono ni deja caer resultados tardíos.
- «Usar el equipo» comparte ruta con la acción: solo se ofrece si la regla automática llegaría de
  verdad a una máquina (las que ya dijeron `unsupported` no cuentan) y se revalida al pulsar.
- La limpieza diferida del reconocedor va por instancia (`domain/RecogniserSlot`): la de un intento
  viejo ya no puede destruir el motor que otro intento acaba de crear.
- «Usar el equipo» sobrevive al diálogo de permiso como intención y se revalida al arrancar; si el
  último equipo se fue mientras el diálogo estaba abierto, se dice en vez de arrancar el móvil.
- 24 pruebas JVM nuevas (recuperación del motor, idioma del reconocedor, la barra antes de cualquier
  resultado, invalidación de intentos, limpieza por instancia, máquinas rechazadas y candidato que
  desaparece durante el permiso). 268 tests, 0 fallos.
- PROBADO EN EL PIXEL por el usuario tras el arreglo: el dictado local ya funciona y transcribe en
  vivo a la cajita. La calidad es mala («me entiende fatal»), así que el camino bueno sigue siendo
  Whisper del equipo. Lo del umbral de 1,5 s es heurística nuestra, no un diagnóstico del modelo
  ausente, y los extras de silencio pueden ser ignorados por el motor: documentado como tal.

## Retoque visual del compositor (10 de septiembre de 2026)

- Visto por el usuario en el Pixel con captura: mientras la barra de dictado está activa, «Solo
  texto» se partía en vertical (una letra por línea) porque la línea de ayuda reclamaba todo su
  ancho y dejaba al botón un hueco de pocos píxeles.
- La línea de ayuda pasa a tener peso y recorte con puntos suspensivos, «Solo texto» se retira
  mientras se dicta o se transcribe (ahí ya estaba deshabilitado), y los botones del aviso van a una
  línea sin salto. Las barras de grabación y de transcripción respiran a la derecha como el campo.
- El rótulo de la barra se acorta a «Grabando para el equipo»: la explicación de Listo y Cancelar ya
  estaba en la línea de ayuda de abajo, así que sobraba repetirla y le quitaba sitio al cronómetro.
- No verificado en pantalla por mí: no abro emuladores ni instalo en el móvil. Es maquetación
  razonada, pendiente de que el usuario la mire en el Pixel, y conviene comprobarla también con el
  tema Nieve y con la fila de teclas abierta.
