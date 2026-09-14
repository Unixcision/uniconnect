# Relanzar la IA sin cambiar de conversación

Estado de esta entrega: implementación Linux en validación. Esta guía no significa
que la función ya esté instalada en tu app ni que Mac/Android estén validados.
Las superficies de esos clientes se coordinan en el mismo repositorio.

## Qué botón necesitas

- **Relanzar IA** cierra la instancia del agente y abre una nueva con la misma
  conversación. Sirve, por ejemplo, después de que tú hayas cambiado la cuenta
  utilizada por ese proveedor en el equipo donde corre. No realiza el login por ti.
- **Reconectar** vuelve a conectar la vista/terminal: no equivale a reiniciar la IA.
- **Continuar** pide retomar un encargo. Es independiente del relanzado; no se envía
  automáticamente ni se interpreta como aceptar permisos. En Linux la entrega
  verificada de ese mensaje todavía se devuelve como no soportada.

Relanzar no crea una conversación nueva, no mata tmux, no borra archivos ni cambia
deliberadamente permisos. Conserva los argumentos de configuración reconocidos y
la carpeta del proceso. Si no puede acreditar el resultado, lo indica; no muestra
un éxito solo porque haya reaparecido una terminal.

## Después de cambiar de cuenta

1. Completa tú el cambio de cuenta **en el equipo donde se ejecuta la IA**. Si
   la ventana es SSH a DESA, el login relevante es el de DESA, no el del visor Linux.
2. Relanza primero una ventana y comprueba conversación, cuenta y posibilidad de
   escribir. No hace falta crear otra conversación para cargar una cuenta cambiada.
3. Después aplica el mismo flujo al espacio o al alcance global que necesites.

Se conserva el entorno/perfil del proceso. Si dos ventanas usan perfiles o
directorios de configuración diferentes, un login en uno no cambia el otro.
UniConnect no copia tokens entre perfiles, no cambia de proveedor y no inicia sesión
por ti. Si vuelve un aviso de autenticación, resuélvelo en el perfil de esa ventana.

## Una ventana

1. Selecciona la ventana en UniConnect.
2. Abre **IA → Relanzar IA de esta ventana…**, o el menú contextual de su pestaña,
   terminal o entrada de la barra lateral y elige la misma acción.
3. Revisa el plan y pulsa **Aplicar**. **Cancelar** no cierra nada.
4. Espera al resultado **Verificado** para esa ventana.

Antes de aplicar, deja el cuadro de escritura de la IA vacío y resuelve tú los
diálogos pendientes. Un borrador, un permiso o un estado desconocido detienen ese
objetivo sin contestar por ti. Guarda tu trabajo: el relanzado detiene la ejecución
del agente, no termina automáticamente las tareas que estuviera haciendo.

## Todo un espacio de trabajo

1. Selecciona el espacio.
2. Elige **IA → Relanzar IA de este espacio…**, o la misma acción con clic derecho
   sobre el espacio en la barra lateral.
3. La previsualización enumera sus ventanas y los objetivos excluidos con su motivo.
4. Confirma. Cada ventana tiene su propio resultado: que una falle no convierte las
   demás en fallidas ni oculta esa incidencia.

Las ventanas añadidas después de preparar el plan no se incluyen. Si cambias un
proceso o una conexión mientras revisas, prepara otro plan para ese objetivo.

El permiso y el destino se comprueban de nuevo antes de enviar cada relanzado.
Una vez que el trabajador de destino ha aceptado ese cierre/reapertura, deja
terminar ese ciclo para no dejarte una shell vacía; revocar acceso impide los
siguientes envíos, pero no deshace un cierre que ya fue admitido. La pérdida de
conexión no se interpreta por sí sola como una revocación.

## Este equipo y global

**IA → Relanzar IA de este equipo…** reúne las ventanas locales y SSH de esta
instalación de UniConnect, de todos sus espacios. Incluye las IA en VPS que se ven
desde estas ventanas; no se limita a procesos locales de Linux.

**IA → Relanzar IA globalmente…** añade los otros equipos conocidos/autorizados de
la red personal. En Linux configura ese inventario en **IA → Equipos del alcance
global…**: nombre, dirección Tailscale/MagicDNS y puerto de cada host UniConnect.
Es un directorio de conexiones salientes, independiente de quién tenga permiso
para entrar aquí. No se escanea una red ni se conceden permisos nuevos. Cada
destino debe tener UniConnect escuchando en su puerto configurado y autorizar a
este equipo; aprobar un móvil para entrar aquí no concede el permiso inverso.
Un dispositivo sin host UniConnect, inaccesible o sin capacidad `relaunch.v1`
aparece excluido. Comprueba la lista: un equipo no registrado no está incluido.
Añade instalaciones UniConnect, no cada destino SSH: los VPS ya entran a través
de sus ventanas. Quitar un equipo del directorio no cierra sus sesiones ni revoca
permisos; solo lo deja fuera de futuros planes globales.

El cliente pide un plan independiente a cada equipo y muestra las exclusiones.
Dos vistas del mismo panel SSH no deben producir dos reinicios: la exclusión mutua
vive en el destino real. El segundo intento se informa como duplicado.

**Global siempre requiere revisar y confirmar el plan.** No es una orden de
reiniciar todos los procesos de una máquina: solo los objetivos de IA inventariados.

## Entender el resultado

| Resultado | Qué significa / qué hacer |
|---|---|
| Pendiente / Cerrando / Reabriendo | La operación sigue en curso. |
| Verificado | Se comprobó una instancia nueva y la misma conversación en el mismo panel. |
| Necesita tu intervención | Revisa esa ventana, login, permiso o borrador. No se ha contestado por ti. |
| Omitido | Objetivo duplicado o cambiado; revisa el motivo. |
| No completado | No hay prueba de éxito; no lo des por reiniciado. |

Usa **Actualizar estado** si se cortó la conexión. Consultar o recuperar la misma
operación no vuelve a cerrar una IA ya atendida. Si cerraste el diálogo o UniConnect,
abre **IA → Resultados de relanzados…** y elige la operación anterior: ese recibo
solo consulta, nunca vuelve a aplicar. No prepares y apliques repetidamente
planes nuevos para resolver un corte: primero revisa el resultado y la ventana.
El token de un plan nuevo caduca a los 120 segundos; si aún no lo habías aplicado,
debes preparar otro. Una operación ya aceptada se recupera con su identidad original.

Si aparece una shell en lugar de la IA, **no está verificado**. Tampoco lo está si
la reapertura exige resolver confianza, autenticación o cualquier otro diálogo.

## Proveedores y límites de esta implementación Linux

El inventario no oculta proveedores desconocidos. La sintaxis compartida contiene
17 proveedores, pero eso no demuestra que los 17 se puedan cerrar/reabrir con
seguridad. Actualmente el adaptador de proceso Linux implementa evidencia para
**Codex y Claude**: proceso vivo, generación y conversación observada mediante
metadatos nativos/archivos abiertos, no el ID antiguo de la ventana. **Identificar
no basta para cerrar**: el cierre automático Linux exige además evidencia de
turno terminado y configuración efectiva de Codex. Claude sigue excluido del
cierre automático hasta disponer de esa comprobación de ciclo de vida.

- Otros proveedores: **no soportado** hasta tener adaptador y pruebas de ciclo de
  vida propios. No se ejecuta un comando aproximado.
- Supervisores personalizados, sesiones con múltiples paneles ambiguos, argumentos
  no reconocidos, falta de evidencia o plataforma remota no Linux: se excluyen.
- Un supervisor externo puede relanzar por su cuenta; el adaptador no lo modifica.
- Una IA cuyo cierre no termina limpiamente no recibe SIGKILL ni pulsaciones a ciegas.
- Los argumentos explícitos se conservan; no se añade bypass de permisos. Si el
  modelo, esfuerzo, carpeta o política efectivos de Codex no coinciden con la
  configuración comprobable del lanzamiento, el objetivo se excluye antes de cerrar.
  También se excluyen perfiles/configuraciones que este adaptador no sabe acreditar,
  incluidos permisos de escritura con raíces ampliadas. No se cambia su configuración
  para hacerlos compatibles.
- No escribas en la ventana mientras se aplica su relanzado; un mensaje nuevo
  cambia el estado que acabas de confirmar.

Para Codex se utiliza la forma documentada `codex resume <SESSION_ID>`, no
`--last`. Si cambia la carpeta, Codex puede pedir elegirla; no se responde de
forma automática. [Referencia oficial de comandos de Codex](https://learn.chatgpt.com/docs/developer-commands?surface=cli).

## Desde Android y Mac

La operativa acordada es la misma, con plan previo y resultados por objetivo:

- **Ventana:** menú contextual de esa ventana; en Android, pulsación larga.
- **Espacio:** menú del espacio; en Android, pulsación larga sobre el espacio.
- **Equipo:** menú del equipo elegido, sin limitarlo a la ventana visible.
- **Global:** acción global del cliente que reúne equipos autorizados y muestra
  también los inaccesibles. No confundirla con el menú de un solo equipo.

En Android las órdenes viajan al host por `relaunch.plan/apply/status`; el móvil
no ejecuta un cierre por teclas. Si el host no anuncia `relaunch.v1`, no está
disponible. Ante pérdida de red se consulta la operación original; no se crea otra
para «probar». **Esta sección describe la operativa común, no certifica que los
menús de tu versión Android/Mac ya estén entregados.** Su interfaz y validación
nativa pertenecen al tramo de esos clientes y siguen pendientes de cierre conjunto.

## Comprobación humana antes de dar la función por terminada

Probar primero una ventana sin trabajo activo. Comprobar que vuelve la conversación
correcta, que puede escribirse y que configuración/archivos siguen como estaban.
Después probar un espacio y, por último, global con un equipo inaccesible y un
panel SSH visible desde dos hosts. Las pruebas Linux no sustituyen esta validación
ni una prueba nativa de Mac/Android.
