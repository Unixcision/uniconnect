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
| `errors.json` | Errores de la llamada, distintos de las causas por objetivo. |
| `causes.json` | Causas estables por objetivo. El texto en español lo pone el cliente. |

Regla que se comprueba con `apply-recovered-response.json`: **recuperar el resultado de algo que ya
se hizo no puede exigir un plan nuevo.** Si lo exigiera, un corte de red entre el cierre y la
respuesta se convertiría en trabajo perdido, que es justo lo que este contrato existe para evitar.
