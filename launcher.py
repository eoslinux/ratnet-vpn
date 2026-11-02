"""Точка входа для сборки RatnetVPN.exe (и обычного запуска тоже)."""
from __future__ import annotations

import os
import sys
import traceback


# --------------------------------------------------------------------------
#  вывод в «оконной» сборке
# --------------------------------------------------------------------------
def _ensure_stdout() -> str | None:
    """В windowed-сборке sys.stdout пуст. Пробуем подключиться к консоли
    родителя, иначе пишем в файл. Возвращает путь к файлу (или None)."""
    if sys.stdout is not None and sys.stderr is not None:
        return None
    try:
        import ctypes

        if ctypes.windll.kernel32.AttachConsole(-1):  # ATTACH_PARENT_PROCESS
            sys.stdout = open("CONOUT$", "w", encoding="utf-8", errors="replace", buffering=1)
            sys.stderr = open("CONOUT$", "w", encoding="utf-8", errors="replace", buffering=1)
            return None
    except Exception:
        pass
    path = os.path.join(os.environ.get("TEMP", "."), "ratnet-cli.log")
    try:
        f = open(path, "w", encoding="utf-8", errors="replace")
        sys.stdout = f
        sys.stderr = f
        return path
    except OSError:
        return None


# --------------------------------------------------------------------------
#  аварийный журнал: если приложение упало, окна с ошибкой нет
# --------------------------------------------------------------------------
def _install_crash_log() -> None:
    def handler(exc_type, exc, tb):
        text = "".join(traceback.format_exception(exc_type, exc, tb))
        path = os.path.join(os.environ.get("TEMP", "."), "ratnet-crash.log")
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
        except OSError:
            path = "(не удалось записать файл)"
        try:
            import tkinter as tk
            from tkinter import messagebox

            root = tk.Tk()
            root.withdraw()
            messagebox.showerror("Ratnet VPN", f"Приложение остановлено из-за ошибки.\n\n{exc}\n\nОтчёт: {path}")
            root.destroy()
        except Exception:
            pass

    sys.excepthook = handler


# --------------------------------------------------------------------------
#  самопроверка сборки: RatnetVPN.exe --selftest
# --------------------------------------------------------------------------
def _selftest() -> None:
    from ratnet import gui

    out = os.path.join(os.environ.get("TEMP", "."), "ratnet-selftest.txt")
    with open(out, "w", encoding="utf-8") as f:
        f.write(f"frozen={getattr(sys, 'frozen', False)}\n")
        f.write(f"meipass={getattr(sys, '_MEIPASS', '')}\n")
        f.write(f"scripts={gui.SCRIPTS}\n")
        f.write(f"exists={os.path.isdir(gui.SCRIPTS)}\n")
        if os.path.isdir(gui.SCRIPTS):
            f.write("files:\n")
            for name in sorted(os.listdir(gui.SCRIPTS)):
                f.write(f"  {name}\n")
        try:
            import paramiko

            f.write(f"paramiko={paramiko.__version__}\n")
        except Exception as e:  # noqa: BLE001
            f.write(f"paramiko=MISSING ({e})\n")
        host = os.environ.get("RATNET_TEST_HOST", "").strip()
        if host:
            try:
                from ratnet import actions
                from ratnet.ssh import Node

                node = Node(host, key_path=os.environ.get("RATNET_TEST_KEY") or None,
                            password=os.environ.get("RATNET_TEST_PASS") or None)
                st = actions.read_state(node)
                f.write(f"ssh=OK host={host} transport={st['transport']} clients={len(st['rows'])}\n")
                f.write(f"lifetime_gb={st['lifetime_bytes'] / 1073741824:.2f}\n")
                for row in st["rows"]:
                    f.write(f"  {row['name']}\t{row['used_gb']:.2f} ГБ\t{row['limit_gb']}\n")
                if os.environ.get("RATNET_TEST_STREAM") == "1":
                    import time

                    t0 = time.monotonic()

                    def on_line(line: str) -> None:
                        f.write(f"stream[{time.monotonic() - t0:4.1f}s] {line}\n")
                        f.flush()

                    node.run("for i in 1 2 3; do echo поток-строка $i; sleep 1; done",
                             timeout=40, on_output=on_line)
                    node.close()
            except Exception as e:  # noqa: BLE001
                f.write(f"ssh=FAIL {e}\n")
    print(out)


def main() -> None:
    if "--selftest" in sys.argv:
        _ensure_stdout()
        _selftest()
        return

    if len(sys.argv) > 1:
        log_path = _ensure_stdout()
        from ratnet.cli import main as cli_main

        code = cli_main(sys.argv[1:])
        if log_path:
            try:
                import tkinter as tk
                from tkinter import messagebox

                root = tk.Tk()
                root.withdraw()
                messagebox.showinfo("Ratnet VPN", f"Готово. Результат записан в файл:\n{log_path}")
                root.destroy()
            except Exception:
                pass
        raise SystemExit(code)

    _install_crash_log()
    from ratnet.gui import main as gui_main

    gui_main()


if __name__ == "__main__":
    main()
