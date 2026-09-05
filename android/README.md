# UniConnect para Android

Cliente nativo Kotlin + Jetpack Compose. Interfaz en español, sin WebView, sin
Stack Auth ni cuentas de terceros. Las máquinas se configuran explícitamente por
dirección Tailscale y puerto (58465 inicialmente).

## Estado real

- Splash nativo con el logo original de UniConnect, tema azul noche/cian/violeta.
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
fijados en el proyecto. No requiere abrir Android Studio.

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
