# Firma estable e instalación local

macOS asocia permisos de privacidad a la identidad firmada de una aplicación. Una firma ad-hoc
genera un designated requirement basado en hashes de código que cambia al recompilar; por eso una
actualización puede parecer otra aplicación y volver a solicitar Accesibilidad, Captura de pantalla
o automatización. UniConnect no instala builds ad-hoc.

Referencias de Apple:

- [Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
- [Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Introduction/Introduction.html)
- [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)

## Build local estable

`scripts/build-local-release.sh` busca exactamente una identidad **Apple Development** con su clave
privada, construye Release sin firma automática en DerivedData persistente y firma el bundle de
dentro hacia fuera. Nunca instala ni abre la app.

```bash
./scripts/build-local-release.sh
```

Si el Mac tiene varias identidades Apple Development, hay que elegirla explícitamente:

```bash
UNICONNECT_SIGNING_IDENTITY=<sha1-o-nombre-exacto> ./scripts/build-local-release.sh
```

El script termina mostrando la ruta exacta de `UniConnect.app`. La comprobación final exige:

- firma profunda y estricta válida;
- bundle ID `com.unixcision.uniconnect`;
- firma no ad-hoc;
- TeamIdentifier presente;
- designated requirement estable, no basado solo en `cdhash`.

## Instalación protegida

El instalador es dry-run por defecto:

```bash
./scripts/install.sh --app "/ruta/a/UniConnect.app"
```

Antes de modificar `/Applications` compara la identidad candidata con la instalada. Una app estable
solo puede actualizarse con el mismo TeamIdentifier y satisfaciendo el designated requirement de la
instalación anterior. Bundle ID incorrecto, firma manipulada, identidad distinta o candidato ad-hoc
se rechazan antes de cerrar el proceso o crear el swap.

La primera migración desde la antigua instalación ad-hoc requiere consentimiento explícito:

```bash
./scripts/install.sh \
  --app "/ruta/a/UniConnect.app" \
  --allow-one-time-adhoc-migration
```

El comando anterior sigue siendo dry-run. La mutación necesita además `--apply`; abrir la app es otra
decisión separada mediante `--launch`. En el flujo de entrega solo se usa tras completar build,
tests, auditorías, commits y push, y después de la autorización final del usuario.

Al aplicar, el instalador:

1. valida íntegramente el candidato;
2. copia y compara byte a byte la app anterior bajo
   `~/.uniconnect/backups/install/<fecha>/UniConnect.app`;
3. copia el candidato a una ruta de staging y vuelve a validarlo;
4. solicita el cierre limpio y confirma la salida del proceso exacto;
5. intercambia los bundles con rollback automático;
6. vuelve a verificar la firma instalada;
7. conserva el backup y no abre la app salvo `--launch`.

La copia antigua puede ser precisamente la firma ad-hoc o inválida que se está migrando. Por ello el
backup se valida comparando su contenido con el origen, no exigiendo que esa firma histórica pase una
verificación que ya fallaba.

## Distribución

La publicación usa una identidad **Developer ID Application**, notarización y stapling. El script
`scripts/build-sign-upload.sh` ya no contiene el hash de otra organización: exige
`UNICONNECT_DEVELOPER_IDENTITY` desde el entorno privado. Una Apple Development local sirve para este
Mac, pero no sustituye Developer ID ni la notarización para distribución pública.

## Pruebas del guard

```bash
./scripts/test-uniconnect-signature-guard.sh
```

La prueba crea bundles temporales y verifica continuidad estable, rechazo de candidato ad-hoc,
migración ad-hoc/invalid explícita, bundle ID incorrecto y manipulación posterior a la firma. No toca
`/Applications`, sesiones, historial ni permisos TCC.
