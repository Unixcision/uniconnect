# Avisos privados en Android

La conexión es directa entre tus máquinas por Tailscale. No hay Firebase/FCM,
servidor de notificaciones externo, cuenta de Google ni intermediario de UniConnect.

## Activación y privacidad

Desde una máquina conectada, «Mantener conexión y avisos» explica consumo de
batería/datos y pide autorización de notificaciones. Solo después de aceptar se
mantiene una conexión con ese ordenador mientras usas otras aplicaciones.
La notificación permanente permite detener todas las conexiones. También puedes
desactivar una máquina desde su pantalla. Como máximo hay ocho máquinas activas.

El permiso contextual es `POST_NOTIFICATIONS` en Android 13 o posterior. Rechazarlo
no impide usar las terminales en primer plano. Si se bloquea el canal de avisos, no
se registra una entrega que Android no puede mostrar.
[Permiso oficial de notificaciones](https://developer.android.com/develop/ui/compose/notifications/notification-permission).

Los avisos muestran únicamente el nombre de la máquina y un mensaje genérico;
no copian salida de terminal, prompts, secretos ni el cuerpo de la notificación
remota. En pantalla bloqueada se utiliza una versión aún más genérica. El registro
privado conserva solo identificadores de avisos ya gestionados, hasta 4096 por
máquina, y no participa en copias de seguridad Android.

Tocar un aviso busca exactamente la máquina, espacio y ventana originales. No
crea ni reinicia terminales, no marca leída la notificación del escritorio y no
activa ventanas del Mac. Si ya no existe el destino, lo indica.

## Servicio y restricciones reales

Se utiliza un servicio visible `connectedDevice`: mantiene interacción de red con
un ordenador externo seleccionado expresamente. Declara los permisos de servicio
y `CHANGE_NETWORK_STATE` correspondientes; no solicita Bluetooth, ubicación,
captura de pantalla ni exclusiones de batería. No cambia la VPN ni abre puertos.
[Tipos oficiales de servicio en primer plano](https://developer.android.com/develop/background-work/services/fgs/service-types#connected-device).

No hay reinicio oculto al arrancar el móvil. Si Android detiene el servicio,
el usuario debe volver a activarlo. No se usa un servicio solo para evitar Doze.
El modo de ahorro puede suspender la red, y un proceso visible no garantiza avisos
instantáneos con pantalla apagada. Al recuperar conectividad se vuelve a conectar
y se consultan los avisos que el host todavía conserva. FCM es la recomendación
de Google para entrega durante reposo, pero no se ha añadido porque este producto
debe funcionar sin esa nube. No se promete equivalencia con un servicio push.
[Doze y App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby).

## Contrato y recuperación

Primero se suscribe a `notification.created`, luego pagina
`mobile.notifications.list` mediante cursor opaco. Lista y eventos pasan por el
mismo coordinador de entregas, que deduplica por máquina e ID estable. Los avisos
leídos se registran sin alertar. La escritura del registro sucede después de
publicar; la etiqueta estable del sistema sustituye un aviso pendiente si el
proceso murió entre ambos pasos. No se afirma entrega exactamente una vez ante
cualquier interrupción. Los avisos anteriores al límite local pueden repetirse.

El host conserva notificaciones vigentes, no un historial infinito. Los avisos
sustituidos o eliminados mientras el móvil está desconectado pueden no recuperarse.
Un heartbeat de 30 segundos detecta conexiones silenciosamente caídas; la espera
progresiva de reconexión llega a 30 segundos. Revocación y falta de autorización
detienen la conexión, no provocan una sucesión ilimitada de solicitudes.

## Comprobación manual pendiente

Usar solo la máquina y terminal de pruebas aisladas. Sin desactivar Tailscale
ni forzar Doze mientras ADB sea la única vía de acceso remoto:

1. Rechazar permiso: las terminales siguen funcionando y no aparece servicio.
2. Aceptar: aparece conexión permanente con acción «Detener».
3. Crear un aviso de prueba real en el host; comprobar aviso genérico en Android.
4. Reconsultar/reconectar: no repetir el mismo ID ya entregado.
5. Tocar el aviso: abrir la ventana original sin crear una nueva.
6. Revocar en la UI del host: cerrar la conexión y no reconectar sin aprobación.
7. Probar pantalla apagada/ahorro solo con una vía de recuperación independiente;
   medir el retraso observado, no deducirlo de una prueba con la pantalla encendida.

Las pruebas unitarias del coordinador cubren duplicados, separación entre
máquinas, avisos leídos y permiso fallido. Se compilan localmente; se ejecutan
en CI según el contrato del repositorio.
