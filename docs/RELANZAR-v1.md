# `relaunch.v1` — reconectar, relanzar y continuar

Contrato común para Mac, Linux y Android, válido igual para cajas locales y SSH.

Nace de un encargo concreto: poder rehacer lo que el 14-09-2026 se hizo a mano — cerrar y reabrir
26 Claude locales del Mac uno por uno — desde la propia UniConnect, para **una ventana, un espacio
de trabajo o todo el sistema conectado**, y desde cualquiera de los tres clientes.

Lo que sigue está escrito a partir de lo que se rompió haciéndolo a mano y de la revisión de CODEX
VPS y del backend. Cada regla tiene detrás un incidente real, no una preferencia de estilo.

## 1. Tres verbos, nunca uno

Mezclarlos es lo que convierte «reconectar» en «perder trabajo». Son operaciones distintas y el
usuario las pide en momentos distintos.

| Verbo | Qué hace | Qué NO hace |
|---|---|---|
| `transport.reconnect` | Reengancha el cliente a lo que ya está corriendo. | No cierra la IA. No toca el proceso. |
| `agent.relaunch` | Cierra el agente y lo reabre **sobre la misma conversación**. | No mata tmux. No cambia permisos, modelo ni carpeta. |
| `agent.continue` | Le dice a un agente vivo que retome el encargo anterior. | No es un OK en blanco: va acotado a ese encargo. |

`transport.reconnect` es el caso mayoritario: quien ve una ventana en blanco casi siempre quiere
esto y no relanzar nada. En SSH es además *el* caso, porque lo que se cae es el transporte mientras
el tmux remoto sigue vivo.

**Compatibilidad, no reinvención.** Los caminos que ya existen se conservan con su semántica; el
verbo nuevo es estricto y **no hereda sus atajos**. Son dos plataformas con dos historias distintas
y conviene no mezclarlas:

- **Mac.** `v2MobileTerminalReconnect` ya reconecta durable en local y SSH y explícitamente no
  relanza la IA; `UniConnectCoordinator.reconnectAllSSHWindowsNow` agrega el transporte SSH.
  `transport.reconnect` reutiliza esa ruta.
- **Linux.** `mobile_rpc.py` trata hoy `terminal.reconnect`/`reset` como `surface.launch()`, y esa
  llamada **no crea tmux**: `launch(create=False)` → `terminal_launch(create=False)` →
  `TmuxCommand.attach` comprueba `has-session`, sale 72 si falta y usa `attach-session`. Ese camino
  no se convierte en un cierre de IA implícito.

**Y una trampa que hay que nombrar**: en Linux, la ruta de escritorio con la carpeta local borrada
puede abrir una **shell de recuperación** en vez de la conversación. Un panel con una shell ahí
**no es `verificado`**: el verbo nuevo comprueba que el panel y el transporte son los que esperaba y,
si no lo son, devuelve `fallido`. Enseñar una shell de recuperación como «reconectado» es mentir con
un tic verde.

`transport.reconnect` **no crea ni reanuda nada de forma implícita**. Si no hay a qué reengancharse,
falla y lo dice; no inventa una sesión. Los alias antiguos siguen funcionando como siempre para
quien ya los usa.

Para reanudar, Linux ya comparte sintaxis en `resume_catalog.py` →
`Packages/CMUXAgentLaunch/…/agent-resume-v1.json`. Se reutiliza; no se crea otro catálogo.

## 2. Alcance

```
scope = { kind: "window" | "workspace" | "machine", id }
```

**No existe un alcance «todo el sistema» en el protocolo.** Lo compone el cliente pidiendo `machine`
a cada equipo. Así el abanico y sus fallos parciales se ven en el cliente, y un host no puede
esconder que otro no contestó.

`machine` significa **host UniConnect** (el Mac, el Linux), nunca «destino SSH». Las ventanas SSH de
un host entran en el `machine` de ese host.

**Deduplicación obligatoria, y por la identidad del objetivo, no la de quien lo mira.** El mismo
panel remoto puede verse desde dos hosts o dos clientes. La clave de identidad es:

```
destino SSH efectivo + usuario + socket/servidor tmux + panel + generación
```

**Nunca el host UniConnect que lo muestra.** Si se usara el host, cada uno se creería dueño del mismo
panel remoto y lo relanzaría por su cuenta: dos registros locales independientes no garantizan «una
vez». Para una caja local, el destino efectivo es esa máquina, y la clave sigue siendo la misma.

Y con la clave no basta: hace falta **autoridad sobre el objetivo**. Un objetivo sin autoridad
resoluble se **excluye**; no se ejecuta «por si acaso». Relanzar dos veces el mismo agente porque se
veía desde dos sitios es un fallo, no un detalle.

**La autoridad vive en el destino, no en cada host.** Dos hosts con su propio registro local no
pueden garantizar «una vez» por mucho que ambos sean cuidadosos: cada uno decide con información que
el otro no tiene. Así que el cerrojo y el diario están **donde está el panel**, en
`~/.local/state/uniconnect/relaunch-v1` de la máquina destino, y la identidad que se arbitra incluye
arranque del sistema, uid, inodo del socket, arranque del servidor tmux, panel y arranque del panel,
más la generación del proceso.

De ahí se sigue algo que simplifica el Mac: **para un objetivo SSH, el Mac no maneja tmux por su
cuenta**. Reutiliza por SSH el mismo trabajador que arbitra en el destino. Un solo ejecutor por
objetivo, y es el que está al lado del panel.

## 3. Dos fases: `plan` y `apply`

`plan` devuelve los objetivos, las exclusiones **con su motivo**, y un token. `apply` solo acepta ese
token. Sin previsualización no hay forma honesta de enseñar «voy a relanzar 26 agentes» antes de
hacerlo, y desde el móvil eso es un toque sin querer.

El token va **vinculado** a:
- el dispositivo autorizado que pidió el plan,
- el verbo,
- la lista exacta de objetivos,
- y la **generación/identidad efectiva de cada objetivo** en el momento del plan.

Y **caduca**. Un token viejo no puede relanzar un proceso nuevo ni arrastrar ventanas que aparecieron
después del plan.

**Revalidación justo antes de actuar.** Si la identidad efectiva o la generación de un objetivo
cambió entre `plan` y `apply`, ese objetivo se **excluye** y se pide un plan nuevo. Un PID o un ID
guardado, por sí solos, no bastan.

Repetir `apply` con el mismo token devuelve **la misma operación**, no otro cierre.

## 4. Estados y resultado

Resultado **por objetivo**, nunca agregado. Cada verbo recorre sus propias fases; solo
`agent.relaunch` cierra y reabre:

```
agent.relaunch      planificado → cerrando → reabriendo → verificado
transport.reconnect planificado → reenganchando → verificado
agent.continue      planificado → entregando → verificado

cualquiera de ellas  →  necesita_usuario | fallido | omitido
```

`verificado` significa cosas distintas en cada uno y hay que comprobarlo, no suponerlo:
`agent.relaunch` exige el **mismo ID efectivo** vivo; `transport.reconnect`, que el transporte
entrega; `agent.continue`, que el agente **acusó recibo** del encargo.

- `verificado` se **comprueba**, nunca se supone, y qué hay que comprobar depende del verbo (ver el
  diagrama de arriba). Lo del **mismo ID efectivo** es exigencia de `agent.relaunch` y solo de él;
  `transport.reconnect` no tiene conversación que comparar y `agent.continue` compara acuse de
  recibo. Un `queued` no se enseña jamás como «IA relanzada».
- `necesita_usuario` es un estado de primera: diálogo no reconocido, confianza de carpeta, permisos.
- Cada motivo es una causa estable (identificador), y el texto en español lo pone el cliente.

**Idempotencia por objetivo y por fase.** Si se cerró la IA y se cortó el SSH antes de recibir el
resultado, el reintento debe **comprobar si ya reabrió** y recuperar el resultado, no cerrarla otra
vez. Se reintentan solo los fallidos.

**Recuperar no es pedir de nuevo, y la caducidad no se aplica igual a las dos cosas:**

| Situación | Qué hace |
|---|---|
| `apply` repetido con un token de una operación **ya aceptada** | Devuelve **esa misma operación** y su estado. Aunque el token haya caducado entretanto: recuperar el resultado de algo que ya se hizo no puede exigir un plan nuevo, o el corte de red se convierte en trabajo perdido. **La excepción es solo a la caducidad**: sigue exigiendo un dispositivo autorizado *ahora* y que sea el dueño de esa operación. Un token caducado no es una llave maestra. |
| `apply` **nuevo** con token caducado | **Rechazado.** No se ejecuta nada. |
| `apply` nuevo con token válido pero un objetivo cuya generación cambió | Ese objetivo **excluido**; el resto sigue. Se pide plan nuevo para él. |

De ahí que el resultado distinga **recuperable** (la operación existe y se consulta) de **fallo que
exige plan nuevo** (la identidad ya no es la del plan). Son dos cosas distintas y el cliente las
enseña distinto: una es «esto ya pasó, mira», la otra es «vuelve a mirar y decide».

Consultar el estado de una operación en curso o terminada es su propia llamada, y **no caduca**
mientras la operación se conserve.

**`apply` no bloquea hasta terminar.** Devuelve en cuanto la operación está aceptada, con los
objetivos en el estado que tengan; el cliente sigue con `relaunch.status`. Y ojo con lo que
significa `recovered: true`: es **«esta operación ya existía»**, no «ya terminó». Una operación
recuperada puede estar todavía en curso, y el campo que dice si terminó es el estado de la
operación, no `recovered`.

## 5. Reglas que no se negocian

1. **Nunca matar tmux.**
2. **Nunca mandar Enter ni Ctrl+C genéricos.**
3. **Nunca aceptar diálogos de permisos ni de confianza** en nombre de nadie. El «¿confías en esta
   carpeta?» llega con **«No, exit» preseleccionado**: contestar a ciegas mata la sesión recién
   abierta. Un diálogo conocido se resuelve eligiendo la opción **por su texto**, nunca por su
   posición.
4. **Diálogo no reconocido o identidad ambigua: se excluye ese objetivo**, se informa y se sigue con
   los demás. Nunca se adivina.
5. **El ID efectivo sale del proceso vivo**, no de los argumentos de arranque. Ni `--last`, ni
   fiarse de lo guardado en la ventana. Medido: de 26 ventanas del Mac, **5 se habían lanzado sin
   `--resume`** y su línea de comandos no decía qué conversación seguir.
6. **Relanzar no cambia nada más**: ni permisos, ni modelo, ni carpeta. Se vuelve como estaba.

## 6. Adaptadores por proveedor

La interfaz común **pide la evidencia al adaptador que corresponde**. Lo que sirve para Codex en
Linux (locks y rollouts) no es un detector universal de Claude, y al revés: leer el
`Resume this session with: <id>` que Claude imprime al salir no vale para Codex.

```
AgentAdapter
  identidadEfectiva(objetivo)  -> id | ambiguo   # ambiguo excluye, no adivina
  cerrar(objetivo)             -> cerrado | necesita_usuario | fallido
  reabrir(objetivo, id)        -> vivo | necesita_usuario | fallido
  continuar(objetivo, encargo) -> aceptado | necesita_usuario | fallido
```

Mismos tres verbos para caja local y SSH; cambia el transporte, no el contrato.

## 7. Superficies

- **Mac y Linux**: menú contextual de la ventana / del espacio, y menú superior.
- **Android**: pulsación larga en la ventana o el espacio, y menú de la máquina.

Un host anuncia `relaunch.v1` en `capabilities`. Quien no lo anuncie no recibe estas peticiones y el
cliente no ofrece la acción, igual que con `ssh_create.v1`.

## 8. Forma normativa: nombres, campos y errores

Los ejemplos vivos están en `contracts/relaunch-v1/`, y **las pruebas de las tres plataformas leen
esos mismos archivos**. Si un ejemplo y una implementación discrepan, manda el ejemplo.

**Llamadas** (mismos nombres en el RPC del móvil y en el socket de escritorio):

| Llamada | Para qué |
|---|---|
| `relaunch.plan` | Previsualiza. Devuelve objetivos, exclusiones con motivo y un token. |
| `relaunch.apply` | Ejecuta el plan de ese token. |
| `relaunch.status` | Consulta una operación por su id. No caduca. Es la que se usa mientras `apply` sigue en curso. |

```jsonc
// relaunch.plan  →  petición
{ "verb": "agent.relaunch", "scope": { "kind": "workspace", "id": "<uuid>" } }

// relaunch.plan  →  respuesta
{
  "operation_id": "<uuid>",
  "token": "<opaco>",
  "expires_at": "2026-09-14T18:30:00Z",   // duración por defecto: 120 s
  "verb": "agent.relaunch",
  "targets": [
    { "key": "<identidad del objetivo>", "label": "PROYECTOS · Claude Code",
      "provider": "claude", "generation": 7, "state": "planificado" }
  ],
  "excluded": [
    { "label": "IMPUESTOS · Codex", "cause": "identidad_ambigua" }
  ]
}

// relaunch.apply  →  petición
{ "operation_id": "<uuid>", "token": "<opaco>" }

// relaunch.apply / relaunch.status  →  respuesta
{
  "operation_id": "<uuid>",
  "recovered": false,                      // true = ya existía; no se ejecutó nada nuevo
  "results": [
    { "key": "<identidad>", "state": "verificado", "effective_id": "<id conversación>" },
    { "key": "<identidad>", "state": "necesita_usuario", "cause": "dialogo_desconocido" }
  ]
}
```

**Causas estables** (identificador en el protocolo; el texto en español lo pone el cliente):
`identidad_ambigua`, `dialogo_desconocido`, `confianza_carpeta`, `permisos`, `sin_autoridad`,
`generacion_cambiada`, `host_inaccesible`, `duplicado`, `no_soportado`.

**Errores de la llamada** (distintos de una causa por objetivo, que no es un error):
`token_caducado`, `token_no_valido`, `operacion_desconocida`, `alcance_no_valido`.

## 9. Pruebas compartidas

Las mismas en los tres lados, porque los fallos son los mismos:

- `apply` repetido con el mismo token → una sola operación.
- Token caducado → rechazo, sin efectos.
- Proceso cambiado entre `plan` y `apply` → objetivo excluido.
- Panel duplicado visible desde dos hosts → se ejecuta una vez.
- Diálogo desconocido → `necesita_usuario`, nada cerrado.
- Corte entre cierre y reapertura → el reintento recupera, no vuelve a cerrar.
- Ventana añadida después del plan → no entra sin un plan nuevo.
- Cliente antiguo llamando a `terminal.reconnect` → comportamiento de siempre, sin cierre de IA.
- `apply` de una operación ya aceptada, con el token **caducado** → se recupera, `recovered: true`.
- `apply` **nuevo** con token caducado → `token_caducado`, sin efectos.
- Mismo panel remoto alcanzable desde dos hosts → un solo ejecutor; el otro lo da por `duplicado`.
- Objetivo sin autoridad resoluble → `sin_autoridad`, excluido, nada cerrado.
- `apply` devuelve con objetivos a medias → `operation_state: "en_curso"`, y `relaunch.status` los
  termina de contar. `apply` no bloquea.
- Recuperar con token caducado desde un dispositivo **no autorizado** o que **no es el dueño** de la
  operación → rechazado. La excepción es a la caducidad, no a la autorización.
- Reconectar un panel cuya carpeta local ya no existe y acaba en shell de recuperación → `fallido`,
  nunca `verificado`.

## 10. Pendiente de decisión del usuario

Si `apply` sobre un alcance grande pide **confirmación explícita** o va directo. Afecta al cliente,
no a la forma del contrato: `plan`/`apply` ya da el mecanismo para enseñar lo que va a pasar. Está
preguntado y no se presupone.
