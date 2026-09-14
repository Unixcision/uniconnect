# Ejemplos normativos de `relaunch.v1`

Estos archivos **son el contrato**, no una ilustración. Las pruebas de Mac, Linux y Android leen
estos mismos ficheros; si un ejemplo y una implementación discrepan, manda el ejemplo.

El documento que los explica es `docs/RELANZAR-v1.md`.

| Archivo | Qué fija |
|---|---|
| `plan-request.json` | Forma de `relaunch.plan`. |
| `plan-response.json` | Objetivos, exclusiones con causa, token y caducidad. |
| `apply-request.json` | Forma de `relaunch.apply`. |
| `apply-response.json` | Resultado por objetivo de un `apply` que sí ejecutó. |
| `apply-recovered-response.json` | Un `apply` repetido de una operación ya aceptada: `recovered: true`, no se ejecuta nada nuevo, y vale aunque el token haya caducado. |
| `apply-in-progress-response.json` | `apply` no bloquea hasta terminar: devuelve con `operation_state: "en_curso"` y el cliente sigue con `relaunch.status`. |
| `status-request.json` | Forma de `relaunch.status`. |
| `errors.json` | Errores de la llamada, distintos de las causas por objetivo. |
| `causes.json` | Causas estables por objetivo. El texto en español lo pone el cliente. |

Dos campos que se confunden y no son lo mismo: **`recovered`** dice que la operación **ya existía**,
y **`operation_state`** dice si **terminó**. Una operación recuperada puede seguir en curso.

Regla que se comprueba con `apply-recovered-response.json`: **recuperar el resultado de algo que ya
se hizo no puede exigir un plan nuevo.** Si lo exigiera, un corte de red entre el cierre y la
respuesta se convertiría en trabajo perdido, que es justo lo que este contrato existe para evitar.

Y una que se comprueba mirando quién pide: la excepción de caducidad al recuperar es **solo a la
caducidad**. Sigue haciendo falta un dispositivo autorizado ahora y que sea el dueño de esa
operación. Un token caducado no es una llave maestra.
