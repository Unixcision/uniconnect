#!/usr/bin/env python3
"""Falla si una suite de pruebas no llegó a ejecutarse, o no ejecutó lo que debía.

`xcodebuild -only-testing:cmuxTests/LoQueSea` informa «Executed 0 tests» y termina en
verde cuando esa suite no está cableada en el pbxproj, o cuando se renombra y nadie
actualiza el flujo de trabajo. Un verde así es indistinguible de una regresión que nadie
comprobó, y es exactamente como un par rojo/verde deja de demostrar nada.

Lee el **bundle de resultados**, no el registro: el registro imprime totales de la
ejecución entera sin decir a qué suite pertenece cada prueba, así que una suite mencionada
con cero casos y otra con seis satisfarían cualquier comprobación hecha sobre el texto. El
bundle identifica cada caso con `Suite/prueba()`, que es atribución de verdad.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys


class ResultadoDePruebas:
    """Los casos que un bundle `.xcresult` dice haber ejecutado."""

    def __init__(self, arbol: dict) -> None:
        self._casos: list[tuple[str, str]] = []
        self._recorrer(arbol.get("testNodes", []))

    def _recorrer(self, nodos: list) -> None:
        for nodo in nodos:
            if nodo.get("nodeType") == "Test Case":
                self._casos.append(
                    (nodo.get("nodeIdentifier", ""), nodo.get("result", "Desconocido"))
                )
            self._recorrer(nodo.get("children", []))

    @classmethod
    def desde(cls, ruta: str) -> "ResultadoDePruebas":
        salida = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "tests",
             "--path", ruta, "--format", "json"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        return cls(json.loads(salida))

    def casos_de(self, suite: str) -> list[tuple[str, str]]:
        """Los casos que pertenecen a `suite`, por identificador y no por texto suelto."""
        prefijo = suite + "/"
        return [(ident, res) for ident, res in self._casos if ident.startswith(prefijo)]

    @property
    def total(self) -> int:
        return len(self._casos)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xcresult", required=True, help="bundle de resultados de xcodebuild")
    parser.add_argument(
        "--suite",
        required=True,
        help="nombre de la clase de la suite, tal y como aparece en -only-testing",
    )
    parser.add_argument(
        "--minimum",
        type=int,
        default=1,
        help="casos que como mínimo deben haberse ejecutado en esa suite",
    )
    args = parser.parse_args()

    try:
        resultado = ResultadoDePruebas.desde(args.xcresult)
    except (subprocess.CalledProcessError, json.JSONDecodeError, OSError) as error:
        print(f"ERROR: no se pudo leer {args.xcresult}: {error}", file=sys.stderr)
        return 1

    casos = resultado.casos_de(args.suite)
    if not casos:
        print(
            f"ERROR: la suite «{args.suite}» no ejecutó ningún caso "
            f"(el bundle tiene {resultado.total} en total). Casi siempre significa que su "
            "fichero no está cableado en cmux.xcodeproj/project.pbxproj y Xcode lo ignora "
            "en silencio, o que la suite se renombró y el flujo de trabajo no.",
            file=sys.stderr,
        )
        return 1

    fallados = [ident for ident, res in casos if res != "Passed"]
    if fallados:
        print(
            f"ERROR: {len(fallados)} de {len(casos)} casos de «{args.suite}» no pasaron:",
            file=sys.stderr,
        )
        for ident in fallados:
            print(f"  - {ident}", file=sys.stderr)
        return 1

    if len(casos) < args.minimum:
        print(
            f"ERROR: «{args.suite}» ejecutó {len(casos)} casos y se esperaban al menos "
            f"{args.minimum}. Puede que se hayan borrado pruebas sin querer.",
            file=sys.stderr,
        )
        return 1

    print(f"ok: «{args.suite}» ejecutó {len(casos)} casos y todos pasaron.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
