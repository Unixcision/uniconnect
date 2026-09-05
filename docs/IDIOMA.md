# UniConnect en español

Decisión del producto del 5 de septiembre de 2026: la interfaz de UniConnect
para macOS y Linux, y la futura aplicación Android nativa, se mantiene únicamente
en español. No se modifica el idioma del sistema, de los comandos ejecutados,
de las conversaciones de IA ni de los nombres elegidos por el usuario.

## Fuente de los textos

- `Resources/Localizable.xcstrings`: catálogo compartido del escritorio.
- `Resources/InfoPlist.xcstrings`: permisos y servicios de macOS.
- `Packages/CmuxSwiftRenderUI/Sources/CmuxSwiftRenderUI/Resources/Localizable.xcstrings`:
  mensajes del renderizador de barras laterales personalizadas.

Estos catálogos declaran `sourceLanguage: es` y solo contienen `localizations.es`.
Las claves, los comandos y sus argumentos, los identificadores del protocolo y
los marcadores de formato no se traducen. Los textos nuevos y sus valores de
reserva sí deben escribirse en español. No se mantiene un segundo diccionario
de traducciones para Linux.

Las preferencias antiguas (`system`, `en`, `ja`, etc.) siguen siendo legibles al
importar configuraciones, pero no habilitan otros idiomas. El esquema para nuevas
configuraciones ofrece únicamente `app.language: es`; en Ajustes se informa del
idioma sin ofrecer un selector. Esta migración no elimina datos de sesiones.

## Verificación

Compilar la aplicación macOS con `./scripts/reload.sh --tag <etiqueta>` sin
lanzarla. Revisar el `.app` resultante: región de desarrollo `es`, localizaciones
propias solo en español y textos compilados presentes en `es.lproj`.

Las pruebas de comportamiento de preferencias antiguas, resolución de textos y
menús de Linux se ejecutan en CI. No ejecutar pruebas localmente. Comprobar las
cadenas compiladas, además de analizar JSON, para detectar fallos de distribución.

La suite heredada de XCUITest aún contiene búsquedas por títulos en inglés y
preferencias `AppleLanguages=(en)`: debe migrarse a identificadores de accesibilidad
o expectativas en español antes de usarla como prueba completa del escritorio.
Este cambio no afirma que esa suite E2E esté validada. Algunos detalles de errores
técnicos antiguos de Linux y los mensajes emitidos por herramientas externas
pueden conservar su texto original; no se modifican códigos del protocolo.

No se borran traducciones de dependencias, ejemplos, la web o el proyecto iOS:
son superficies distintas de esta entrega de escritorio. Android será nativo y
solo en español; todavía no se instala ni migra ninguna sesión local a tmux en
este cambio de idioma.
