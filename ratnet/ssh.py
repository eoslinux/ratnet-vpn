"""SSH-обёртка для Ratnet VPN."""
from __future__ import annotations

import os
import socket
import time
import paramiko


class SSHError(RuntimeError):
    pass


class Node:
    """Подключение к серверу по SSH (пароль или ключ)."""

    def __init__(self, host: str, user: str = "root", port: int = 22,
                 password: str | None = None, key_path: str | None = None,
                 timeout: int = 20):
        self.host = host.strip()
        self.user = user.strip() or "root"
        self.port = int(port or 22)
        self.password = password
        self.key_path = (key_path or "").strip() or None
        self.timeout = timeout
        self._client: paramiko.SSHClient | None = None

    # --- lifecycle -----------------------------------------------------
    def connect(self) -> "Node":
        if self._client:
            return self
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        kwargs = dict(
            hostname=self.host,
            port=self.port,
            username=self.user,
            timeout=self.timeout,
            banner_timeout=self.timeout,
            auth_timeout=self.timeout,
            allow_agent=False,
            look_for_keys=False,
        )
        try:
            if self.key_path:
                if not os.path.exists(self.key_path):
                    raise SSHError(f"ключ не найден: {self.key_path}")
                kwargs["key_filename"] = self.key_path
            else:
                if not self.password:
                    raise SSHError("не задан ни пароль, ни ключ")
                kwargs["password"] = self.password
            client.connect(**kwargs)
        except paramiko.AuthenticationException as e:
            raise SSHError(f"неверный логин, пароль или ключ ({e})") from e
        except (socket.timeout, OSError) as e:
            raise SSHError(f"нет связи с {self.host}:{self.port} ({e})") from e
        except Exception as e:  # noqa: BLE001
            raise SSHError(str(e)) from e
        self._client = client
        return self

    def close(self) -> None:
        if self._client:
            try:
                self._client.close()
            finally:
                self._client = None

    def __enter__(self) -> "Node":
        return self.connect()

    def __exit__(self, *exc) -> None:
        self.close()

    # --- commands ------------------------------------------------------
    def run(self, command: str, timeout: int = 600, check: bool = False,
            on_output=None) -> tuple[int, str, str]:
        """Выполнить команду.

        Если передан on_output, вывод отдаётся построчно сразу, по мере поступления
        (stdout и stderr вместе). Иначе — как раньше: читаем всё и возвращаем.
        """
        self.connect()
        assert self._client is not None
        try:
            stdin, stdout, stderr = self._client.exec_command(command, timeout=timeout)
            chan = stdout.channel
            if on_output is None:
                out = stdout.read().decode("utf-8", "replace")
                err = stderr.read().decode("utf-8", "replace")
                rc = chan.recv_exit_status()
            else:
                chan.set_combine_stderr(True)
                chan.settimeout(1.0)
                deadline = time.monotonic() + timeout
                chunks: list[bytes] = []
                pending = ""
                while True:
                    try:
                        data = chan.recv(4096)
                    except socket.timeout:
                        if time.monotonic() > deadline:
                            chan.close()
                            raise SSHError("команда не завершилась за отведённое время")
                        continue
                    if not data:
                        break
                    chunks.append(data)
                    pending += data.decode("utf-8", "replace")
                    while "\n" in pending:
                        line, pending = pending.split("\n", 1)
                        on_output(line.rstrip("\r"))
                if pending.strip():
                    on_output(pending.rstrip("\r"))
                out = b"".join(chunks).decode("utf-8", "replace")
                err = ""
                rc = chan.recv_exit_status()
        except Exception as e:  # noqa: BLE001
            self.close()
            raise SSHError(f"ошибка выполнения команды: {e}") from e
        if check and rc != 0:
            raise SSHError((err or out).strip() or f"команда завершилась с кодом {rc}")
        return rc, out, err

    def upload(self, local_path: str, remote_path: str) -> None:
        self.connect()
        assert self._client is not None
        sftp = self._client.open_sftp()
        try:
            sftp.put(local_path, remote_path)
            sftp.chmod(remote_path, 0o755)
        finally:
            sftp.close()

    def ping(self) -> str:
        rc, out, _ = self.run("hostname; . /etc/os-release; echo $PRETTY_NAME", timeout=20)
        if rc != 0:
            raise SSHError("сервер не ответил")
        return out.strip()
