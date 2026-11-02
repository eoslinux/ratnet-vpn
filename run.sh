#!/usr/bin/env bash
# Запуск Ratnet VPN на Linux/macOS
cd "$(dirname "$0")" || exit 1
export PYTHONUTF8=1
PY=python3
command -v "$PY" >/dev/null 2>&1 || PY=python
exec "$PY" -m ratnet.gui
