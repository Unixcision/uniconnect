#!/usr/bin/env python3
"""Falla si una suite de pruebas no llegó a ejecutarse.

`xcodebuild -only-testing:cmuxTests/LoQueSea` informa «Executed 0 tests» y termina en
verde cuando esa suite no está cableada en el pbxproj, o cuando se renombra y nadie
actualiza el flujo de trabajo. Un verde así es indistinguible de una regresión que
nadie comprobó, y es exactamente como un test rojo/verde deja de demostrar nada.

Se usa después de `xcodebuild ... test` o `test-without-building`, sobre su registro.
"""
from __future__ import annotations

import argparse
import re
import sys


class Registro:
    """El registro de una ejecución de xcodebuild, leído para saber qué corrió."""

    def __init__(self, texto: str) -> None:
        self._texto = texto

    def pruebas_ejecutadas(self) -> int:
        """Cuántas pruebas dice el registro que se ejecutaron.

        Cuenta las dos formas que emite Swift Testing y la de XCTest, y se queda con
        la mayor: mezclar marcos en una misma invocación es legítimo y no debe restar.
        """
        totales = [0]
        swift_testing = re.search(
            r"Test run with (\d+) test", self._texto
        )
        if swift_testing:
            totales.append(int(swift_testing.group(1)))
        totales.append(len(set(re.findall(r'Test "([^"]+)" (?:passed|failed)', self._texto))))
        totales.extend(
            int(n) for n in re.findall(r"Executed (\d+) test", self._texto)
        )
        return max(totales)

    def menciona(self, suite: str) -> bool:
        return suite in self._texto


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, help="registro de xcodebuild")
    parser.add_argument("--suite", required=True, help="nombre visible de la suite")
    parser.add_argument(
        "--minimum",
        type=int,
        default=1,
        help="pruebas que como mínimo deben haberse ejecutado",
    )
    args = parser.parse_args()

    with open(args.log, "r", encoding="utf-8", errors="replace") as archivo:
        registro = Registro(archivo.read())

    ejecutadas = registro.pruebas_ejecutadas()
    if not registro.menciona(args.suite):
        print(
            f"ERROR: la suite «{args.suite}» no aparece en el registro. "
            "Casi siempre significa que su fichero no está cableado en "
            "cmux.xcodeproj/project.pbxproj y Xcode lo ignora en silencio.",
            file=sys.stderr,
        )
        return 1
    if ejecutadas < args.minimum:
        print(
            f"ERROR: se ejecutaron {ejecutadas} pruebas y se esperaban al menos "
            f"{args.minimum}. Un «Executed 0 tests» en verde no demuestra nada.",
            file=sys.stderr,
        )
        return 1

    print(f"ok: «{args.suite}» ejecutó {ejecutadas} pruebas (mínimo {args.minimum}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
