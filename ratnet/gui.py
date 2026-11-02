"""Графический интерфейс Ratnet VPN (Tkinter)."""
from __future__ import annotations

import os
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, simpledialog, ttk

from . import actions
from .paths import SCRIPTS, base_dir
from .ssh import Node, SSHError

APP_NAME = "Ratnet VPN"
BASE = base_dir()


# --------------------------------------------------------------------------
#  буфер обмена: Ctrl+V / Ctrl+C / Ctrl+X / Ctrl+A и меню по правой кнопке
# --------------------------------------------------------------------------
def _win_clipboard_text() -> str:
    """Читает текст из буфера Windows напрямую (если Tk не смог)."""
    try:
        import ctypes

        user32 = ctypes.windll.user32
        kernel32 = ctypes.windll.kernel32
        kernel32.GlobalLock.restype = ctypes.c_void_p
        kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
        kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
        user32.GetClipboardData.restype = ctypes.c_void_p
        user32.OpenClipboard.argtypes = [ctypes.c_void_p]

        if not user32.OpenClipboard(None):
            return ""
        try:
            handle = user32.GetClipboardData(13)  # CF_UNICODETEXT
            if not handle:
                return ""
            ptr = kernel32.GlobalLock(handle)
            if not ptr:
                return ""
            try:
                return ctypes.wstring_at(ptr)
            finally:
                kernel32.GlobalUnlock(handle)
        finally:
            user32.CloseClipboard()
    except Exception:  # noqa: BLE001
        return ""


def _clip_text(widget) -> str:
    try:
        text = widget.clipboard_get()
        if text:
            return text
    except tk.TclError:
        pass
    # запасной путь: буфер Windows (бывает, что Tk не видит чужой формат)
    return _win_clipboard_text()


def _select_all(widget) -> None:
    if isinstance(widget, tk.Text):
        widget.tag_add("sel", "1.0", "end-1c")
        widget.mark_set("insert", "1.0")
    else:
        widget.selection_range(0, "end")
        widget.icursor("end")


def _win_set_clipboard(text: str) -> bool:
    """Кладёт текст в буфер Windows — переживает закрытие приложения."""
    try:
        import ctypes

        user32 = ctypes.windll.user32
        kernel32 = ctypes.windll.kernel32
        kernel32.GlobalAlloc.restype = ctypes.c_void_p
        kernel32.GlobalAlloc.argtypes = [ctypes.c_uint, ctypes.c_size_t]
        kernel32.GlobalLock.restype = ctypes.c_void_p
        kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
        kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
        user32.SetClipboardData.restype = ctypes.c_void_p
        user32.SetClipboardData.argtypes = [ctypes.c_uint, ctypes.c_void_p]
        user32.OpenClipboard.argtypes = [ctypes.c_void_p]

        data = text.encode("utf-16-le") + b"\x00\x00"
        handle = kernel32.GlobalAlloc(0x0042, len(data))
        if not handle:
            return False
        ptr = kernel32.GlobalLock(handle)
        if not ptr:
            return False
        ctypes.memmove(ptr, data, len(data))
        kernel32.GlobalUnlock(handle)

        if not user32.OpenClipboard(None):
            return False
        try:
            user32.EmptyClipboard()
            return bool(user32.SetClipboardData(13, handle))  # CF_UNICODETEXT
        finally:
            user32.CloseClipboard()
    except Exception:  # noqa: BLE001
        return False


def _set_clipboard(widget, text: str) -> None:
    if _win_set_clipboard(text):
        return
    widget.clipboard_clear()
    widget.clipboard_append(text)


def _copy(widget) -> str:
    if isinstance(widget, tk.Text):
        try:
            text = widget.get("sel.first", "sel.last")
        except tk.TclError:
            return "break"
    else:
        if not widget.selection_present():
            return "break"
        text = widget.selection_get()
    _set_clipboard(widget, text)
    return "break"


def _cut(widget) -> str:
    _copy(widget)
    if isinstance(widget, tk.Text):
        try:
            widget.delete("sel.first", "sel.last")
        except tk.TclError:
            pass
    else:
        if widget.selection_present():
            widget.delete("sel.first", "sel.last")
    return "break"


def _paste(widget) -> str:
    text = _clip_text(widget)
    if not text:
        return "break"
    if isinstance(widget, tk.Text):
        try:
            widget.delete("sel.first", "sel.last")
        except tk.TclError:
            pass
        widget.insert("insert", text)
    else:
        if widget.selection_present():
            widget.delete("sel.first", "sel.last")
        widget.insert("insert", text)
    return "break"


def attach_clipboard(widget, editable: bool = True) -> None:
    """Привязывает привычные сочетания и меню по правой кнопке."""
    widget.bind("<Control-c>", lambda e: _copy(widget))
    widget.bind("<Control-C>", lambda e: _copy(widget))
    widget.bind("<Control-a>", lambda e: (_select_all(widget), "break")[1])
    widget.bind("<Control-A>", lambda e: (_select_all(widget), "break")[1])
    if editable:
        widget.bind("<Control-v>", lambda e: _paste(widget))
        widget.bind("<Control-V>", lambda e: _paste(widget))
        widget.bind("<Shift-Insert>", lambda e: _paste(widget))
        widget.bind("<Control-x>", lambda e: _cut(widget))
        widget.bind("<Control-X>", lambda e: _cut(widget))

    def copy_line() -> None:
        idx = getattr(widget, "_click_index", None) or "insert"
        _set_clipboard(widget, widget.get(f"{idx} linestart", f"{idx} lineend"))

    def copy_all() -> None:
        _set_clipboard(widget, widget.get("1.0", "end-1c"))

    menu = tk.Menu(widget, tearoff=0)
    if editable:
        menu.add_command(label="Вырезать", command=lambda: _cut(widget))
    menu.add_command(label="Копировать", command=lambda: _copy(widget))
    if editable:
        menu.add_command(label="Вставить", command=lambda: _paste(widget))
    if isinstance(widget, tk.Text):
        menu.add_command(label="Копировать строку", command=copy_line)
        menu.add_command(label="Копировать всё", command=copy_all)
    menu.add_separator()
    menu.add_command(label="Выделить всё", command=lambda: _select_all(widget))
    widget._clip_menu = menu  # чтобы меню не собрал сборщик мусора

    def popup(event):
        try:
            widget.focus_set()
        except tk.TclError:
            pass
        if isinstance(widget, tk.Text):
            try:
                widget._click_index = widget.index(f"@{event.x},{event.y}")
            except tk.TclError:
                widget._click_index = None
        try:
            menu.tk_popup(event.x_root, event.y_root)
        finally:
            menu.grab_release()
        return "break"

    widget.bind("<Button-3>", popup)

    if isinstance(widget, tk.Text):
        # двойной клик — слово, тройной — строка (удобно копировать IP из журнала)
        def sel_word(event):
            widget.tag_remove("sel", "1.0", "end")
            widget.tag_add("sel", f"@{event.x},{event.y} wordstart", f"@{event.x},{event.y} wordend")
            return "break"

        def sel_line(event):
            widget.tag_remove("sel", "1.0", "end")
            widget.tag_add("sel", f"@{event.x},{event.y} linestart", f"@{event.x},{event.y} lineend")
            return "break"

        widget.bind("<Double-Button-1>", sel_word)
        widget.bind("<Triple-Button-1>", sel_line)


class Field:
    """Строка ввода с подписью."""

    def __init__(self, parent, row: int, label: str, value: str = "", width: int = 26, show: str = ""):
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", padx=(0, 8), pady=3)
        self.var = tk.StringVar(value=value)
        self.entry = ttk.Entry(parent, textvariable=self.var, width=width, show=show)
        self.entry.grid(row=row, column=1, sticky="we", pady=3)
        attach_clipboard(self.entry, editable=True)

    def get(self) -> str:
        return self.var.get().strip()

    def set(self, v: str) -> None:
        self.var.set(v)


class App(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title(f"{APP_NAME} — управление транзитным VPN")
        self.geometry("1280x860")
        self.minsize(1100, 760)

        self.exit_token = ""
        self._busy = False

        nb = ttk.Notebook(self)
        nb.pack(fill="both", expand=True, padx=10, pady=10)

        self.tab_servers = ttk.Frame(nb)
        self.tab_clients = ttk.Frame(nb)
        nb.add(self.tab_servers, text="  Серверы  ")
        nb.add(self.tab_clients, text="  Клиенты  ")

        if os.environ.get("RATNET_TAB", "").lower() in ("clients", "клиенты", "2"):
            nb.select(1)

        self._build_servers()
        self._build_clients()
        self._prefill_from_env()

        self.status = tk.StringVar(value="Готово")
        ttk.Label(self, textvariable=self.status, anchor="w", relief="sunken").pack(
            fill="x", side="bottom", padx=0, pady=0)

        # чтобы сразу можно было печатать и вставлять из буфера
        self.after(120, lambda: self.ru_host.entry.focus_set())

    # ------------------------------------------------------------------
    #  вкладка «Серверы»
    # ------------------------------------------------------------------
    def _build_servers(self) -> None:
        top = ttk.Frame(self.tab_servers)
        top.pack(fill="both", expand=True)

        left = ttk.LabelFrame(top, text=" Вход — Россия ")
        left.pack(side="left", fill="both", expand=True, padx=(0, 6), pady=4)
        right = ttk.LabelFrame(top, text=" Выход — иностранная нода ")
        right.pack(side="left", fill="both", expand=True, padx=(6, 0), pady=4)
        for f in (left, right):
            f.columnconfigure(1, weight=1)
            f.columnconfigure(3, weight=0)

        # --- RU ---
        self.ru_host = Field(left, 0, "IP или домен", width=24)
        self.ru_port = Field(left, 1, "SSH порт", "22", width=8)
        self.ru_user = Field(left, 2, "Пользователь", "root", width=12)
        self.ru_key = Field(left, 3, "Ключ (файл)", width=24)
        ttk.Button(left, text="…", width=3, command=lambda: self._pick_key(self.ru_key)).grid(
            row=3, column=2, padx=4)
        self.ru_pass = Field(left, 4, "Пароль", show="•", width=24)
        ttk.Label(left, text="(если указан ключ — пароль не нужен)").grid(
            row=5, column=1, sticky="w", pady=(0, 6))

        ttk.Separator(left, orient="horizontal").grid(row=6, column=0, columnspan=3, sticky="we", pady=8)

        ttk.Label(left, text="Транспорт входа").grid(row=7, column=0, sticky="w")
        self.transport = ttk.Combobox(left, values=["reality", "tls", "hysteria2"],
                                      state="readonly", width=14)
        self.transport.set("reality")
        self.transport.grid(row=7, column=1, sticky="w", pady=3)
        self.entry_port = Field(left, 8, "Порт входа", "443", width=8)
        self.entry_sni = Field(left, 9, "Домен / CN", width=24)

        # блокировка рекламы: состояние показываем индикатором рядом с кнопкой
        self.adblock_on = False
        adf = ttk.Frame(left)
        adf.grid(row=10, column=0, columnspan=3, sticky="w", pady=(6, 8))
        ttk.Label(adf, text="Блокировка рекламы:").pack(side="left")
        self.adblock_btn = ttk.Button(adf, text="Переключить", command=self.do_toggle_adblock_entry)
        self.adblock_btn.pack(side="left", padx=6)
        self.adblock_lbl = tk.Label(adf, text="выкл", fg="#888888", font=("", 9, "bold"))
        self.adblock_lbl.pack(side="left")

        bf = ttk.Frame(left)
        bf.grid(row=11, column=0, columnspan=3, sticky="we", pady=4)
        ttk.Button(bf, text="Проверить связь", command=self.do_check_ru).pack(side="left")
        ttk.Button(bf, text="Развернуть вход", command=self.do_deploy).pack(side="left", padx=6)

        df = ttk.Frame(left)
        df.grid(row=12, column=0, columnspan=3, sticky="we", pady=(2, 6))
        ttk.Button(df, text="Очистить вход…", command=lambda: self.do_cleanup("entry")).pack(side="left")
        ttk.Label(df, text="удаляет Xray и всё, что поставил этот софт").pack(side="left", padx=8)

        # --- exit ---
        self.ex_host = Field(right, 0, "IP или домен", width=24)
        self.ex_port = Field(right, 1, "SSH порт", "22", width=8)
        self.ex_user = Field(right, 2, "Пользователь", "root", width=12)
        self.ex_key = Field(right, 3, "Ключ (файл)", width=24)
        ttk.Button(right, text="…", width=3, command=lambda: self._pick_key(self.ex_key)).grid(
            row=3, column=2, padx=4)
        self.ex_pass = Field(right, 4, "Пароль", show="•", width=24)

        ttk.Separator(right, orient="horizontal").grid(row=5, column=0, columnspan=3, sticky="we", pady=8)

        self.ex_tag = Field(right, 6, "Тег выхода", width=18)
        self.ex_tz = Field(right, 7, "Часовой пояс", "Europe/Amsterdam", width=18)
        self.ex_adblock = tk.BooleanVar(value=False)
        ttk.Checkbutton(right, text="Блокировка рекламы на ноде", variable=self.ex_adblock).grid(
            row=8, column=0, columnspan=3, sticky="w", pady=(4, 0))
        self.ex_reboot = tk.BooleanVar(value=True)
        ttk.Checkbutton(right, text="Ребут Пн/Ср/Пт в 05:00", variable=self.ex_reboot).grid(
            row=9, column=0, columnspan=3, sticky="w", pady=(0, 8))

        bf2 = ttk.Frame(right)
        bf2.grid(row=10, column=0, columnspan=3, sticky="we", pady=4)
        ttk.Button(bf2, text="Проверить связь", command=self.do_check_exit).pack(side="left")
        ttk.Button(bf2, text="Подготовить ноду", command=self.do_prepare).pack(side="left", padx=6)
        ttk.Button(bf2, text="Соединить с входом", command=self.do_join).pack(side="left")

        df2 = ttk.Frame(right)
        df2.grid(row=11, column=0, columnspan=3, sticky="we", pady=(2, 6))
        ttk.Button(df2, text="Очистить выход…", command=lambda: self.do_cleanup("exit")).pack(side="left")
        ttk.Label(df2, text="Xray и настройки ноды; docker/nginx не трогает").pack(side="left", padx=8)

        # --- лог ---
        logf = ttk.LabelFrame(self.tab_servers, text=" Журнал ")
        logf.pack(fill="both", expand=True, pady=(8, 0))
        self.log = tk.Text(logf, height=14, wrap="word")
        self.log.pack(side="left", fill="both", expand=True)
        sb = ttk.Scrollbar(logf, orient="vertical", command=self.log.yview)
        sb.pack(side="right", fill="y")
        self.log.configure(yscrollcommand=sb.set, state="disabled")
        attach_clipboard(self.log, editable=False)

    # ------------------------------------------------------------------
    #  вкладка «Клиенты»
    # ------------------------------------------------------------------
    def _build_clients(self) -> None:
        bar = ttk.Frame(self.tab_clients)
        bar.pack(fill="x", pady=(4, 8))
        ttk.Button(bar, text="Обновить", command=self.do_refresh_clients).pack(side="left")
        ttk.Button(bar, text="Создать клиента", command=self.do_create_client).pack(side="left", padx=6)
        ttk.Button(bar, text="Удалить", command=self.do_delete_client).pack(side="left")
        ttk.Button(bar, text="Сбросить лимит", command=self.do_reset_quota).pack(side="left", padx=6)
        ttk.Button(bar, text="Блокировать", command=self.do_block_client).pack(side="left")
        ttk.Button(bar, text="Разблокировать", command=self.do_unblock_client).pack(side="left", padx=6)
        ttk.Button(bar, text="Ссылка", command=self.do_show_link).pack(side="left")
        ttk.Button(bar, text="Копировать ссылку", command=self.do_copy_link).pack(side="left", padx=6)

        cols = ("name", "used", "limit", "status")
        self.tree = ttk.Treeview(self.tab_clients, columns=cols, show="headings", height=16)
        for c, t, w in (("name", "Клиент", 260), ("used", "Израсходовано", 220),
                        ("limit", "Лимит", 170), ("status", "Статус", 220)):
            self.tree.heading(c, text=t)
            self.tree.column(c, width=w, anchor="w", stretch=(c == "name"))
        self.tree.pack(fill="both", expand=True)

        info = ttk.Label(self.tab_clients, text="", anchor="w")
        info.pack(fill="x", pady=(8, 0))
        self.clients_info = info

        linkf = ttk.LabelFrame(self.tab_clients, text=" Ссылка выбранного клиента ")
        linkf.pack(fill="x", pady=(8, 0))
        self.link_box = tk.Text(linkf, height=3, wrap="char")
        self.link_box.pack(fill="x", padx=6, pady=6)
        self.link_box.configure(state="disabled")
        attach_clipboard(self.link_box, editable=False)

    # ------------------------------------------------------------------
    #  утилиты
    # ------------------------------------------------------------------
    def _prefill_from_env(self) -> None:
        """Позволяет предзаполнить поля из переменных окружения (удобно для проверки)."""
        host = os.environ.get("RATNET_HOST", "").strip()
        if not host:
            return
        self.ru_host.set(host)
        self.ru_user.set(os.environ.get("RATNET_USER", "root"))
        if os.environ.get("RATNET_KEY"):
            self.ru_key.set(os.environ["RATNET_KEY"])
        if os.environ.get("RATNET_PASS"):
            self.ru_pass.set(os.environ["RATNET_PASS"])
        if os.environ.get("RATNET_REFRESH") == "1":
            self.after(700, self.do_refresh_clients)

    def _pick_key(self, field: Field) -> None:
        path = filedialog.askopenfilename(title="Выберите приватный ключ")
        if path:
            field.set(path)

    def logline(self, text: str) -> None:
        self.log.configure(state="normal")
        self.log.insert("end", f"[{time.strftime('%H:%M:%S')}] {text}\n")
        # не даём журналу расти бесконечно
        if int(self.log.index("end-1c").split(".")[0]) > 4000:
            self.log.delete("1.0", "1000.0")
        self.log.see("end")
        self.log.configure(state="disabled")

    def emit(self, text: str) -> None:
        """Вывод команды приходит из фонового потока — переносим в главный."""
        if threading.current_thread() is threading.main_thread():
            self.logline(text)
        else:
            try:
                self.after(0, self.logline, text)
            except tk.TclError:
                pass

    def set_status(self, text: str) -> None:
        self.status.set(text)

    def bg(self, fn, on_ok=None, on_err=None, busy="Работаю…"):
        if self._busy:
            messagebox.showinfo(APP_NAME, "Дождитесь завершения текущей операции")
            return
        self._busy = True
        self.set_status(busy)

        def worker():
            try:
                res = fn()
            except Exception as e:  # noqa: BLE001
                self.after(0, lambda: self._done_err(e, on_err))
            else:
                self.after(0, lambda: self._done_ok(res, on_ok))

        threading.Thread(target=worker, daemon=True).start()

    def _done_ok(self, res, cb):
        self._busy = False
        self.set_status("Готово")
        if cb:
            cb(res)

    def _done_err(self, e, cb):
        self._busy = False
        self.set_status("Ошибка")
        self.logline(f"ОШИБКА: {e}")
        if cb:
            cb(e)
        else:
            messagebox.showerror(APP_NAME, str(e))

    # --- узлы ---------------------------------------------------------
    def ru_node(self) -> Node:
        host = self.ru_host.get()
        if not host:
            raise SSHError("укажи IP российской ноды")
        return Node(host, self.ru_user.get() or "root", int(self.ru_port.get() or 22),
                    password=self.ru_pass.get() or None,
                    key_path=self.ru_key.get() or None)

    def exit_node(self) -> Node:
        host = self.ex_host.get()
        if not host:
            raise SSHError("укажи IP иностранной ноды")
        return Node(host, self.ex_user.get() or "root", int(self.ex_port.get() or 22),
                    password=self.ex_pass.get() or None,
                    key_path=self.ex_key.get() or None)

    # --- действия: серверы -------------------------------------------
    def do_check_ru(self):
        def task():
            n = self.ru_node()
            info = n.ping()
            n.close()
            return info
        self.logline(f"Проверяю связь с входом {self.ru_host.get()}…")
        self.bg(task, lambda r: (self.logline(f"Вход доступен: {r.splitlines()[0]}"),
                                 self.set_status("Связь есть")))

    def do_check_exit(self):
        def task():
            n = self.exit_node()
            info = n.ping()
            n.close()
            return info
        self.logline(f"Проверяю связь с выходом {self.ex_host.get()}…")
        self.bg(task, lambda r: (self.logline(f"Выход доступен: {r.splitlines()[0]}"),
                                 self.set_status("Связь есть")))

    def do_deploy(self):
        if not messagebox.askyesno(APP_NAME, "Развернуть/переустановить вход?\n"
                                              "Существующий конфиг будет сохранён в бэкап."):
            return
        transport = self.transport.get()
        port = int(self.entry_port.get() or 443)
        sni = self.entry_sni.get()
        adblock = self.adblock_on
        script = os.path.join(SCRIPTS, "01-ru-entry.sh")

        def task():
            n = self.ru_node()
            out = actions.deploy_entry(n, script, transport, port, adblock, sni,
                                       force=True, on_output=self.emit)
            n.close()
            return out

        def done(out: str):
            self.logline("Вход развёрнут.")
            self.do_refresh_clients()   # заодно узнаём фактическое состояние рекламы

        self.logline(f"Разворачиваю вход: транспорт {transport}, порт {port}…")
        self.bg(task, done, busy="Разворачиваю вход…")

    def set_adblock_indicator(self, on: bool) -> None:
        self.adblock_on = bool(on)
        self.adblock_lbl.configure(text="вкл" if on else "выкл",
                                   fg="#1a7f37" if on else "#888888")

    def do_toggle_adblock_entry(self):
        enable = not self.adblock_on
        self.logline(f"Блокировка рекламы: {'включаю' if enable else 'выключаю'}…")

        def task():
            n = self.ru_node()
            actions.set_adblock(n, enable, on_output=self.emit)
            n.close()
            return enable

        def done(enabled: bool):
            self.set_adblock_indicator(enabled)
            self.logline("Включено" if enabled else "Выключено")

        self.bg(task, done, busy="Меняю правило…")

    def do_prepare(self):
        tag = self.ex_tag.get()
        tz = self.ex_tz.get() or "Europe/Amsterdam"
        adblock = self.ex_adblock.get()
        reboot = self.ex_reboot.get()
        script = os.path.join(SCRIPTS, "02-foreign-node.sh")

        def task():
            n = self.exit_node()
            res = actions.prepare_exit(n, script, adblock, tz, tag, reboot, on_output=self.emit)
            n.close()
            return res
        self.logline(f"Готовлю выход {self.ex_host.get()}…")
        self.bg(task, self._prepared, busy="Готовлю ноду…")

    def _prepared(self, res):
        self.exit_token = res["token"]
        self.logline("Нода подготовлена.")
        self.logline("Токен соединения: " + res["token"][:32] + "…")
        messagebox.showinfo(APP_NAME, "Нода готова.\nТеперь нажми «Соединить с входом».")

    def do_join(self):
        if not self.exit_token:
            if not messagebox.askyesno(APP_NAME, "Токена нет. Подготовить ноду сейчас?"):
                return
            self.do_prepare()
            return
        token = self.exit_token
        script = os.path.join(SCRIPTS, "03-join-node.sh")

        def task():
            n = self.ru_node()
            out = actions.join_node(n, script, token, on_output=self.emit)
            n.close()
            return out
        self.logline("Соединяю выход со входом…")
        self.bg(task, lambda out: self.logline("Соединение выполнено."), busy="Соединяю ноды…")

    # --- возврат сервера в исходное состояние -------------------------
    def _confirm_cleanup(self, name: str) -> bool:
        """Спрашиваем подтверждение словом Yes (регистр и пробелы не важны)."""
        typed = simpledialog.askstring(
            APP_NAME,
            f"Сервер: {name}\n\nДля подтверждения введи: Yes",
            parent=self)
        return bool(typed) and typed.strip().lower() == "yes"

    def do_cleanup(self, side: str):
        host = self.ru_host.get() if side == "entry" else self.ex_host.get()
        if not host:
            messagebox.showinfo(APP_NAME, "Укажи IP сервера, который нужно очистить")
            return
        factory = self.ru_node if side == "entry" else self.exit_node
        script = os.path.join(SCRIPTS, "05-cleanup.sh")
        role = "entry" if side == "entry" else "exit"
        what = "входа" if role == "entry" else "выхода"

        def dry():
            n = factory()
            out = actions.clean_node(n, script, role, on_output=self.emit, dry_run=True)
            n.close()
            return out

        def after_dry(out: str):
            name = actions.cleanup_hostname(out) or host
            removed = [ln.strip() for ln in out.splitlines()
                       if ln.startswith("  /") and ln.strip().endswith(("K", "M", "G", "B"))]
            preview = "\n".join(removed[:10])
            if len(removed) > 10:
                preview += f"\n… и ещё {len(removed) - 10}"
            if not messagebox.askyesno(
                APP_NAME,
                f"Очистить сервер {name} ({what})?\n\n"
                f"Будет удалено:\n{preview or 'ничего не найдено'}\n\n"
                "Docker/AmneziaWG, nginx, node_exporter и правило 22/tcp не затрагиваются.\n"
                "Бэкап сохранится на сервере в /root.\n\n"
                "После очистки профили клиентов перестанут работать."):
                self.logline("Очистка отменена.")
                return
            if not self._confirm_cleanup(name):
                self.logline("Очистка отменена: подтверждение не введено.")
                return
            def real():
                n = factory()
                out2 = actions.clean_node(n, script, role, on_output=self.emit,
                                          dry_run=False, confirm="Yes")
                n.close()
                return out2

            def done(out2: str):
                self.exit_token = ""
                self.last_link = ""
                self.link_box.configure(state="normal")
                self.link_box.delete("1.0", "end")
                self.link_box.configure(state="disabled")
                self.logline(f"Сервер {name} очищен. Бэкап — в /root на сервере.")

            self.bg(real, done, busy="Удаляю…")

        self.logline(f"Собираю список для очистки {what} {host}…")
        self.bg(dry, after_dry, busy="Смотрю, что удалять…")

    def _show_output(self, out: str):
        for line in (out or "").strip().splitlines():
            self.logline(line)
        self.set_status("Готово")

    # --- действия: клиенты -------------------------------------------
    def do_refresh_clients(self):
        def task():
            n = self.ru_node()
            st = actions.read_state(n)
            n.close()
            return st
        self.bg(task, self._fill_clients, busy="Читаю клиентов…")

    def _fill_clients(self, st):
        self.tree.delete(*self.tree.get_children())
        for r in st["rows"]:
            used = f"{r['used_gb']:.2f} ГБ"
            limit = f"{r['limit_gb']} ГБ" if r["limit_gb"] else "без лимита"
            if r["blocked"]:
                status = "заблокирован"
            elif r["hysteria2"]:
                status = "Hysteria2"
            else:
                status = "активен"
            self.tree.insert("", "end", values=(r["name"], used, limit, status))
        life = st["lifetime_bytes"] / 1073741824
        self.clients_info.configure(
            text=f"Транспорт входа: {st['transport']}   |   Всего прокачано за всё время: {life:.2f} ГБ   |   "
                 f"Сервисы: {', '.join(st['services']) or '—'}")
        self.set_adblock_indicator(st.get("adblock", False))
        self.set_status("Список обновлён")

    def _selected_client(self) -> str | None:
        sel = self.tree.selection()
        if not sel:
            messagebox.showinfo(APP_NAME, "Выбери клиента в таблице")
            return None
        return self.tree.item(sel[0], "values")[0]

    def do_create_client(self):
        name = simpledialog.askstring(APP_NAME, "Имя клиента (латиницей):", parent=self)
        if not name:
            return
        lim = simpledialog.askstring(APP_NAME, "Лимит в ГБ (0 — без лимита):", initialvalue="0", parent=self)
        try:
            gb = float((lim or "0").replace(",", "."))
        except ValueError:
            messagebox.showerror(APP_NAME, "Лимит должен быть числом")
            return

        def task():
            n = self.ru_node()
            res = actions.create_client(n, name.strip(), gb, on_output=self.emit)
            n.close()
            return res
        self.bg(task, lambda res: (self.logline(f"Создан клиент {res['name']} ({res['transport']})"),
                                   self._set_link(res["link"]),
                                   self.do_refresh_clients()),
                busy="Создаю клиента…")

    def do_delete_client(self):
        name = self._selected_client()
        if not name or not messagebox.askyesno(APP_NAME, f"Удалить клиента {name}?"):
            return

        def task():
            n = self.ru_node()
            actions.delete_client(n, name, on_output=self.emit)
            n.close()
            return name
        self.bg(task, lambda r: (self.logline(f"Клиент {r} удалён"), self.do_refresh_clients()),
                busy="Удаляю…")

    def do_reset_quota(self):
        name = self._selected_client()
        if not name:
            return

        def task():
            n = self.ru_node()
            actions.reset_quota(n, name, on_output=self.emit)
            n.close()
            return name
        self.bg(task, lambda r: (self.logline(f"Лимит {r} сброшен"), self.do_refresh_clients()),
                busy="Сбрасываю лимит…")

    def _set_blocked(self, name: str, blocked: bool):
        script = os.path.join(SCRIPTS, "04-client-block.sh")

        def task():
            n = self.ru_node()
            out = actions.set_client_blocked(n, script, name, blocked, on_output=self.emit)
            n.close()
            return out
        self.bg(task, lambda out: (self.logline(f"{name}: " + ("доступ отключён" if blocked
                                                                        else "доступ восстановлен, UUID прежний")),
                                            self.do_refresh_clients()),
                busy="Меняю доступ…")

    def do_block_client(self):
        name = self._selected_client()
        if not name or not messagebox.askyesno(APP_NAME, f"Отключить VPN для {name}?\n\n"
                                                         "Профиль и UUID сохранятся — включить обратно можно кнопкой "
                                                         "«Разблокировать»."):
            return
        self._set_blocked(name, True)

    def do_unblock_client(self):
        name = self._selected_client()
        if not name:
            return
        self._set_blocked(name, False)

    def do_show_link(self):
        name = self._selected_client()
        if not name:
            return
        self.logline(f"Запрашиваю ссылку для {name}…")

        def task():
            n = self.ru_node()
            link = actions.link_for(n, name)
            n.close()
            return link
        self.bg(task, self._set_link, busy="Собираю ссылку…", )

    def _set_link(self, link: str):
        self.link_box.configure(state="normal")
        self.link_box.delete("1.0", "end")
        self.link_box.insert("1.0", link)
        self.link_box.configure(state="disabled")
        self.last_link = link
        self.logline("Ссылка готова (кнопка «Копировать ссылку»).")

    def do_copy_link(self):
        link = getattr(self, "last_link", "")
        if not link:
            messagebox.showinfo(APP_NAME, "Сначала получи ссылку")
            return
        _set_clipboard(self, link)
        self.set_status("Ссылка скопирована в буфер обмена")


def main() -> None:
    app = App()
    app.mainloop()


if __name__ == "__main__":
    main()
