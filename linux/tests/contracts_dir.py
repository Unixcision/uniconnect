"""Dónde están los contratos compartidos para los tests de Linux (D8).

Se sube carpeta a carpeta desde este fichero hasta la primera que contiene ``contracts/``.
Si no aparece, o falta el fichero pedido, el test **falla**: nunca se salta en silencio,
porque un test que sale en verde sin haber comparado nada es peor que no tenerlo.
"""

from pathlib import Path


def contract(*parts):
    """Ruta de ``contracts/<parts...>``; AssertionError si no existe."""
    here = Path(__file__).resolve()
    for folder in here.parents:
        root = folder / "contracts"
        if root.is_dir():
            path = root.joinpath(*parts)
            assert path.exists(), "Falta %s: sin él no se puede comprobar el contrato." % path
            return path
    raise AssertionError("No se encontró contracts/ subiendo desde %s" % here)
