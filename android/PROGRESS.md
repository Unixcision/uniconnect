# Base Android — estado de implementación

Actualizado: 2026-09-05. Responsable: agente `bridge_lifecycle_audit`.

## Ya creado

- Proyecto nativo Kotlin + Jetpack Compose, sin WebView ni cuentas externas.
- AGP 8.13.1, Kotlin 2.2.20, Gradle 8.14.3; SDK 36, mínimo 26, JVM 17.
- Límite de compilación: dos trabajadores, memoria de Gradle de 1536 MiB.
- Splash nativo AndroidX, tema oscuro y reutilización automática del PNG canónico
  `design/UniConnect.icon/Assets/uniconnect-icon.png` sin duplicarlo en fuentes.
- Recursos de interfaz solo en español y manifiesto sin copia de seguridad.

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

## Validación pendiente

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
