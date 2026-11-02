@echo off
chcp 65001 >nul
cd /d "%~dp0"
set PYTHONUTF8=1
python -m ratnet.gui
if errorlevel 1 (
  echo.
  echo Не удалось запустить. Проверь, что установлен Python 3.10+ и зависимости:
  echo    python -m pip install -r requirements.txt
  pause
)
