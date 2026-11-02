"""Пути к файлам в исходниках и в собранном .exe."""
from __future__ import annotations

import os
import sys


def base_dir() -> str:
    """Папка, рядом с которой лежит программа (или exe)."""
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _looks_like_scripts(path: str) -> bool:
    try:
        return any(name.endswith(".sh") for name in os.listdir(path))
    except OSError:
        return False


def scripts_dir() -> str:
    """Папка со скриптами 01/02/03.

    Приоритет: папка `scripts` рядом с программой (можно править без пересборки),
    затем встроенная копия внутри .exe или исходников.
    """
    external = os.path.join(base_dir(), "scripts")
    if _looks_like_scripts(external):
        return external

    bundled = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts")
    if _looks_like_scripts(bundled):
        return bundled

    if getattr(sys, "frozen", False):
        meipass = getattr(sys, "_MEIPASS", "")
        for candidate in (os.path.join(meipass, "ratnet", "scripts"),
                          os.path.join(meipass, "scripts")):
            if _looks_like_scripts(candidate):
                return candidate
    return bundled


SCRIPTS = scripts_dir()
