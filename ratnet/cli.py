"""Командная строка Ratnet VPN (для проверки и автоматизации)."""
from __future__ import annotations

import argparse
import json
import os
import sys

from . import actions
from .paths import SCRIPTS
from .ssh import Node


def node_from_args(a) -> Node:
    return Node(a.host, a.user, a.port, password=a.password, key_path=a.key)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="ratnet", description="Ratnet VPN — управление по SSH")
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, default=22)
    p.add_argument("--user", default="root")
    p.add_argument("--password")
    p.add_argument("--key")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status")

    c = sub.add_parser("create")
    c.add_argument("name")
    c.add_argument("--gb", type=float, default=0)

    d = sub.add_parser("delete")
    d.add_argument("name")

    l = sub.add_parser("link")
    l.add_argument("name")

    r = sub.add_parser("reset")
    r.add_argument("name")

    b = sub.add_parser("block")
    b.add_argument("name")

    ub = sub.add_parser("unblock")
    ub.add_argument("name")

    ab = sub.add_parser("adblock")
    ab.add_argument("state", choices=["on", "off"])

    dep = sub.add_parser("deploy")
    dep.add_argument("--transport", default="reality", choices=["reality", "tls", "hysteria2"])
    dep.add_argument("--entry-port", type=int, default=443)
    dep.add_argument("--sni", default="")
    dep.add_argument("--adblock", action="store_true")

    prep = sub.add_parser("prepare")
    prep.add_argument("--adblock", action="store_true")
    prep.add_argument("--tz", default="Europe/Amsterdam")
    prep.add_argument("--tag", default="")
    prep.add_argument("--no-reboot", action="store_true")

    join = sub.add_parser("join")
    join.add_argument("token")
    join.add_argument("--pin", default="")

    cl = sub.add_parser("cleanup", help="вернуть сервер в исходное состояние")
    cl.add_argument("--role", choices=["entry", "exit"], default="entry")
    cl.add_argument("--dry", action="store_true", help="только показать список")
    cl.add_argument("--confirm", default="", help="подтверждение: Yes")
    cl.add_argument("--yes", action="store_true", help="то же, что --confirm Yes")
    cl.add_argument("--with-singbox", action="store_true")
    cl.add_argument("--with-ufw", action="store_true")

    a = p.parse_args(argv)
    n = node_from_args(a)

    try:
        if a.cmd == "status":
            st = actions.read_state(n)
            print(f"транспорт: {st['transport']}   сервисы: {', '.join(st['services'])}")
            print(f"всего прокачано: {st['lifetime_bytes']/1073741824:.2f} ГБ")
            print(f"{'клиент':<14}{'израсходовано':>16}{'лимит':>12}  статус")
            for row in st["rows"]:
                lim = f"{row['limit_gb']} ГБ" if row["limit_gb"] else "—"
                stt = "заблокирован" if row["blocked"] else ("hy2" if row["hysteria2"] else "активен")
                print(f"{row['name']:<14}{row['used_gb']:>14.2f} ГБ{lim:>12}  {stt}")

        elif a.cmd == "create":
            res = actions.create_client(n, a.name, a.gb)
            print(f"создан: {res['name']} ({res['transport']})")
            print(res["link"])

        elif a.cmd == "delete":
            actions.delete_client(n, a.name)
            print("удалён")

        elif a.cmd == "link":
            print(actions.link_for(n, a.name))

        elif a.cmd == "reset":
            actions.reset_quota(n, a.name)
            print("лимит сброшен")

        elif a.cmd == "block":
            out = actions.set_client_blocked(n, os.path.join(SCRIPTS, "04-client-block.sh"), a.name, True)
            print(out)

        elif a.cmd == "unblock":
            out = actions.set_client_blocked(n, os.path.join(SCRIPTS, "04-client-block.sh"), a.name, False)
            print(out)

        elif a.cmd == "adblock":
            print(actions.set_adblock(n, a.state == "on"))

        elif a.cmd == "deploy":
            out = actions.deploy_entry(n, os.path.join(SCRIPTS, "01-ru-entry.sh"),
                                       a.transport, a.entry_port, a.adblock, a.sni, True,
                                       on_output=lambda s: print(s, flush=True))
            print(out[-3000:])

        elif a.cmd == "prepare":
            res = actions.prepare_exit(n, os.path.join(SCRIPTS, "02-foreign-node.sh"),
                                       a.adblock, a.tz, a.tag, not a.no_reboot,
                                       on_output=lambda s: print(s, flush=True))
            print(res["output"][-2000:])
            print("\nJOIN_TOKEN=" + res["token"])

        elif a.cmd == "join":
            print(actions.join_node(n, os.path.join(SCRIPTS, "03-join-node.sh"), a.token, a.pin,
                                  on_output=lambda s: print(s, flush=True)))

        elif a.cmd == "cleanup":
            script = os.path.join(SCRIPTS, "05-cleanup.sh")
            if a.dry:
                print(actions.clean_node(n, script, a.role, dry_run=True,
                                         with_singbox=a.with_singbox, with_ufw=a.with_ufw))
            else:
                confirm = a.confirm.strip()
                if not confirm and a.yes:
                    confirm = "Yes"
                if not confirm:
                    print("Нужно подтверждение: --confirm Yes (или --yes)", file=sys.stderr)
                    return 2
                print(actions.clean_node(n, script, a.role, dry_run=False, confirm=confirm,
                                         on_output=lambda s: print(s, flush=True),
                                         with_singbox=a.with_singbox, with_ufw=a.with_ufw))

    except Exception as e:  # noqa: BLE001
        print(f"ОШИБКА: {e}", file=sys.stderr)
        return 1
    finally:
        n.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
