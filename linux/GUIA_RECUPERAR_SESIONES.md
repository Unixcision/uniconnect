# Guía rápida: recuperar sesiones en UniConnect Linux

## Relanzar una IA

1. En la ventana que quieres recuperar, abre el menú contextual y elige **Relanzar IA**.
2. Elige uno de los tres alcances:
   - **Ventana**: solo esa terminal.
   - **Espacio de trabajo**: todas las terminales de ese espacio.
   - **Equipo**: todas las terminales de esta instancia de UniConnect.
3. Revisa la vista previa. **Global** no es un cuarto alcance: en este menú significa **Equipo**. Las ventanas excluidas muestran el motivo.
4. Aplica el plan solo cuando el objetivo, la conversación y la configuración sean los esperados. UniConnect conserva la sesión tmux y reabre la misma conversación; marca el resultado como verificado cuando confirma la identidad y configuración originales.

Una ventana con una IA trabajando puede avisar antes de cerrarla. Aplicar el plan puede interrumpir esa generación; espera a que termine si quieres conservarla. Si hay un borrador, diálogo, identidad o configuración no reconocidos, la ventana debe quedar excluida. No fuerces su cierre desde el terminal.

`codex update` actualiza el ejecutable en el equipo donde corre ese Codex; no cambia el TUI que ya está abierto. Después, usa **Relanzar IA** desde UniConnect para reabrir la misma conversación con la versión nueva. Si la vista previa excluye una sesión activa o no reconocida, déjala abierta: la actualización quedará disponible para el siguiente relanzado seguro.

Para una sesión GEMINI/Antigravity ya abierta, usa primero **Vincular GEMINI abierta de esta ventana…** y confirma el cambio de hooks/status line de UniConnect. La vinculación no cierra la conversación; solo se acepta si el pane, el ID y el estado nativo coinciden. Después revisa la vista previa normal de **Relanzar IA**. `agy update` actualiza el binario instalado, pero no cambia el proceso de un TUI que ya estaba abierto. Si ese proceso no emite una señal reciente e inactiva, o la vista previa lo excluye, déjalo abierto hasta poder verificarlo.

## Continuar una sesión de Codex pausada por cuota

Usa **Reabrir y continuar Codex pausado** y elige el mismo alcance de arriba. La vista previa solo debe incluir sesiones Codex con un aviso reciente de límite de uso y estado inactivo verificado. Tras aplicar, UniConnect reabre la conversación y envía **«continua» una sola vez** cuando confirma que el aviso sigue presente y el compositor está vacío. Comprueba el recibo antes de volver a intentarlo; no repitas el mensaje manualmente.

Un error de inicio de sesión requiere iniciar sesión de nuevo en Codex. UniConnect no cambia cuentas ni credenciales. Un error de red o un diálogo sin reconocer también queda fuera del envío automático.

## Reconectar el terminal

**Reconectar** vuelve a adjuntar la ventana a su sesión tmux existente; no reinicia la IA ni envía texto. Usa **Relanzar IA** cuando lo que necesitas es reabrir el agente conservando su conversación.

Cerrar UniConnect desconecta la interfaz, pero tmux mantiene vivos los procesos remotos. Al abrir la aplicación, selecciona los espacios que quieras volver a mostrar; UniConnect se adjunta a sus sesiones guardadas.

## Detalles y copia del historial

- Menú contextual de una terminal → **Detalles…** para ver la IA detectada, su identificador de conversación cuando se pueda verificar, transporte, tmux, carpeta y orden de reanudación. En Android la opción aparece cuando el equipo anuncia `window_details.v1`.
- Para seleccionar historial tmux, mantén **Mayús** mientras arrastras con el botón izquierdo. En el borde superior puedes mantener pulsado para ampliar la selección mientras avanza el scrollback. Suelta y usa **clic derecho → Copiar** o **Ctrl+Mayús+C**. **Esc** cancela la selección; **Ctrl+C** se envía al programa.
- El texto largo de Codex depende de que su salida esté en el historial tmux. Los lanzamientos gestionados usan `--no-alt-screen`; las sesiones antiguas pueden necesitar un relanzado verificado para adoptar esa opción.

La vista previa y el recibo son la fuente para saber qué ventanas se recuperaron. Si algo no pasa sus comprobaciones, conserva la sesión como está y revisa el motivo antes de actuar.
