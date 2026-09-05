# Revisión del diseño nativo de UniConnect para Linux

Fecha: 2026-09-05. Revisión de código y documentación oficial, seguida de una
primera hoja de estilos autorizada. No se ha ejecutado la aplicación ni realizado
pruebas locales durante esta revisión.

## Conclusión

Es viable conseguir un acabado azul noche, cian y violeta coherente con macOS
manteniendo GTK 3 y VTE. El problema principal no exige otro motor: faltan una
paleta aplicada a toda la estructura, márgenes exteriores consistentes y una
jerarquía que evite repetir barras y acciones.

La edición actual importa `Gtk 3.0` en
[`window.py`](../linux/uniconnect/window.py) y `Vte 2.91` en
[`terminal.py`](../linux/uniconnect/terminal.py).
[`install.sh`](../linux/install.sh) instala las correspondientes dependencias
GTK 3. Al iniciar esta revisión no había proveedor CSS propio; la primera
integración descrita al final ya lo incorpora. Libadwaita
no es una dependencia disponible: incorporarlo requiere migrar a GTK 4, como
explica su [guía oficial de migración](https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1.0/migrating-libhandy-1-4-to-libadwaita.html).
Por tanto, `Adw.ToolbarView` o `Adw.OverlaySplitView` no son sustituciones directas
para esta entrega. Tampoco hace falta introducir un navegador ni dibujar
controles de ventana propios.

## Evidencia en el código actual

- `MainWindow.__init__` superpone `Gtk.HeaderBar`, `Gtk.MenuBar`, una cabecera
  adicional por espacio de trabajo y las pestañas de `Gtk.Notebook`. Cada terminal
  tiene además un pie permanente y la ventana otro indicador inferior.
- El sidebar tiene `margin=10`, pero no una superficie propia con un margen
  exterior separado del relleno interior. El botón de nueva caja aparece tanto
  en la cabecera como en su pie.
- `_render_sidebar` muestra nombre, tipo, contador y todos los nombres de
  ventanas dentro de cada caja; esas ventanas reaparecen como pestañas.
- `action_sidebar` solicita 78 píxeles y oculta la búsqueda al compactar, pero
  mantiene cuatro botones horizontales en el pie. Su tamaño mínimo puede impedir
  ese ancho; debe medirse, no deducirse del valor pasado a `set_position`.
  Al arrancar tampoco se aplica ese ajuste visual desde `compactSidebar` antes
  del `show_all()` final.
- `apply_theme` solo solicita el tema oscuro de GTK. `TerminalSurface.apply_appearance`
  fija por separado `#11151c` y trata «sistema» como oscuro, mientras la estructura
  exterior no hace lo mismo. La resolución del tema debe ser única.

## Seis cambios propuestos

### 1. Una paleta y un fondo continuo

**Prioridad alta; riesgo bajo.** Extraer la resolución visual a un pequeño módulo
`linux/uniconnect/appearance.py` y una hoja `linux/uniconnect/appearance.css`
propuestos; llamarlo desde `window.py:apply_theme` y
`terminal.py:apply_appearance`. Cargar el proveedor una vez, con selectores
acotados a una clase `uniconnect`, sin modificar el tema global del escritorio.

Las referencias reales de macOS son
[`UniConnectSidebarHeaderPalette.swift`](../Sources/UniConnect/UniConnectSidebarHeaderPalette.swift)
y el fondo de inicio de
[`UniConnectViews.swift`](../Sources/UniConnect/UniConnectViews.swift):

| Función | Color existente en macOS |
| --- | --- |
| Azul noche base | `#020A33` |
| Azul elevado | `#05144E` |
| Cian de actividad | `#0BE4FA` |
| Violeta | `#5A1FE5` |
| Acento violeta rosado | `#C344F3` |

Usar la base en toda la ventana y un degradado muy suave en la estructura;
cian/violeta para selección y estados, no grandes bloques saturados. Mantener
VTE opaco, con un fondo sólido coordinado, sin alterar las paletas ANSI de las
sesiones. No aplicar `opacity` a todo el widget: también compone su contenido.
GTK 3 admite colores simbólicos y degradados mediante su
[CSS nativo](https://docs.gtk.org/gtk3/css-overview.html), y documenta la
[composición por opacidad](https://docs.gtk.org/gtk3/css-properties.html).

Para evitar otra paleta independiente, el siguiente paso compartido debe mover
los valores semánticos a un recurso de `Resources/` consumido por ambos
adaptadores. Hoy los números Swift son referencia, no código compartido con
Python. Resolver también «sistema» una sola vez y respetar el tema claro existente.

### 2. Sidebar flotante con márgenes simétricos

**Prioridad alta; riesgo bajo.** En `window.py:__init__` separar el contenedor
exterior del panel interior. Punto de partida, en unidades lógicas GTK: margen
exterior de 12 arriba, izquierda y abajo; separación de 12 con el contenido;
relleno interior de 10–12; radio de 16. Son medidas propuestas, no mediciones de
una captura Linux.

Conservar el mismo fondo base al expandir/compactar. En compacto, apilar las
acciones verticalmente o agrupar las secundarias en un menú; no dejar cuatro
botones horizontales dentro de un carril de 78. Aplicar el mismo método de
presentación al iniciar y al pulsar el botón, conservar el ancho expandido del
usuario y evitar que `show_all()` vuelva a mostrar la búsqueda oculta.

GTK 3 ofrece márgenes de widget y `border-radius`/bordes mediante
[sus propiedades CSS](https://docs.gtk.org/gtk3/css-properties.html). El radio
no debe darse por suficiente para recortar todos los hijos: mantenerlos dentro
del relleno y verificar las esquinas reales. Conservar el área de arrastre del
divisor; no sustituir el `Gtk.Paned` ni mover los controles nativos de cerrar.

### 3. Filas de caja compactas y predecibles

**Prioridad alta; riesgo bajo.** En `window.py:_render_sidebar`, reducir cada
fila expandida a nombre y una segunda línea de estado/tipo/contador; eliminar
la repetición permanente de todas las ventanas. Mantener esos nombres en el
tooltip y en sus pestañas. Propuesta inicial: 48–56 unidades por fila, sin
altura rígida que corte texto ampliado, separación de 6 y selección azul-violeta
discreta con indicador adicional al color.

Conservar los UUID, `row-selected`, el menú contextual y la actualización
diferida existente: es un cambio de presentación, no del ciclo de vida. En
compacto, centrar las iniciales y mantener nombre accesible y aviso de no leído.
GTK permite diferenciar `:selected`, `:hover`, `:focus` y `:backdrop` con
[selectores de estado](https://docs.gtk.org/gtk3/css-overview.html), sin otra
biblioteca. El foco de teclado no debe desaparecer bajo la nueva selección.

### 4. Una cabecera y un menú principal, sin duplicar el «+»

**Prioridad media; riesgo bajo si se conserva el inventario de acciones.** En
`window.py:__init__` y `build_menu`, mantener `Gtk.HeaderBar` con sus controles
nativos; quitar el subtítulo ornamental «Linux» y la reserva de su altura.
Dejar una única acción de nueva caja dentro del sidebar. Agrupar los comandos
menos frecuentes en un `Gtk.MenuButton` que reutilice los grupos y las mismas
acciones `win.*`, sustituyendo la barra de menús permanente.

No confundir menú con la paleta de comandos actual ni quitar acceso a esta;
mantener sus atajos y estados habilitados. Incluir también acceso móvil,
notificaciones, ajustes y bloqueo. GTK 3 permite
[desactivar la reserva de subtítulo](https://docs.gtk.org/gtk3/class.HeaderBar.html)
y asociar al botón un
[menú o popover nativo](https://docs.gtk.org/gtk3/class.MenuButton.html).
La disposición de minimizar/maximizar/cerrar sigue siendo la del escritorio Linux.

### 5. Integrar acciones de terminal en la fila de pestañas

**Prioridad media; riesgo bajo con una precaución de contexto.** En
`window.py:_build_workspace`, retirar la cabecera adicional con título y dos
botones: mostrar el nombre de la caja activa en la cabecera principal y colocar
«Nueva ventana» junto a las pestañas. `Gtk.Notebook.set_action_widget` permite
añadir controles antes o después de ellas, incluido un `Gtk.Box` para agruparlos;
está disponible desde GTK 2.20 según la
[documentación oficial](https://docs.gtk.org/gtk3/method.Notebook.set_action_widget.html).

Mantener la creación por la ruta compartida actual, con el contexto explícito
del espacio/panel pulsado: al haber divisiones, no debe crear ni reconectar en
el panel que conservaba el foco por casualidad. No reconstruir `TerminalSurface`
ni relanzar SSH para cambiar el aspecto; conservar arrastre, orden, cierre y
fijado de pestañas. En espacios vacíos mantener la llamada a crear visible.

### 6. Estado discreto en reposo, errores visibles

**Prioridad media; riesgo bajo.** En `terminal.py:__init__`/`update_status` y
`window.py:__init__`/actualización del estado, no reservar una barra permanente
por cada división cuando todas funcionan. Mostrar la conexión/reconexión/error
con su botón de reintento en una franja contextual; dejar directorio/repositorio
del terminal seleccionado en una sola línea de estado, sin repetirlo por panel.

`Gtk.Revealer` es una opción GTK 3 para esa franja; respeta la preferencia de
animaciones de GTK según su
[referencia oficial](https://docs.gtk.org/gtk3/class.Revealer.html).
No ocultar fallos, operaciones activas ni acciones de recuperación. La transición
visual no debe lanzar conexiones ni cambiar el estado del proceso.

## Orden de implementación y aceptación

Primero 1–3: máximo impacto visual sin reorganizar los comandos. Después 4–6,
comprobando todos los accesos compartidos de
[`actions.py`](../linux/uniconnect/actions.py) y
[`window_commands.py`](../linux/uniconnect/window_commands.py).

La validación pendiente debe cubrir ventana y pantalla completa, cada una con
sidebar compacto/expandido; 100 %/200 %, texto ampliado, oscuro/claro/sistema,
selección activa/inactiva y muchas pestañas/divisiones. Comprobar márgenes
reales y anchos mínimos, no solo constantes de código. En CI o VM, cargar CSS
con errores GTK tratados como fallos y verificar que alternar el diseño conserva
UUID y proceso de terminal, selección, atajos, menús y creación Local/SSH.

No se han añadido cadenas de interfaz. Este documento está íntegramente en
español; la implementación deberá reutilizar las claves actuales y añadir
cualquier etiqueta nueva al único catálogo español
[`Resources/Localizable.xcstrings`](../Resources/Localizable.xcstrings).
La propuesta no acredita paridad funcional ni sustituye las limitaciones
documentadas en [`linux/PORT_STATUS.md`](../linux/PORT_STATUS.md).

## Primera integración autorizada

Se ha añadido [`appearance.css`](../linux/uniconnect/appearance.css), con
selectores propios de UniConnect, colores oscuros detrás de `uc-dark`, márgenes
internos, esquinas, selección, foco y pestañas. El responsable de Linux conecta
el proveedor y las clases desde sus archivos; conserva GTK 3 y las superficies
VTE existentes. La hoja no redefine la transparencia de VTE ni cambia acciones,
conexiones o sesiones.

Esto es una primera mejora de estilo, **no los seis cambios ya terminados**:
la eliminación de barras, la compactación de las filas, la reorganización de
acciones del carril compacto y los pies contextuales quedan pendientes. La
aceptación visual y el análisis CSS real en GTK Linux corresponden al siguiente
gate en CI/VM; un archivo de estilos escrito no demuestra todavía su resultado.
