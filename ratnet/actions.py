"""Операции над серверами Ratnet VPN (всё через SSH)."""
from __future__ import annotations

import base64
import json
import shlex
from urllib.parse import quote

from .ssh import Node


# --------------------------------------------------------------------------
#  чтение состояния
# --------------------------------------------------------------------------
STATE_CMD = r"""
echo "@@@ENV"
cat /root/ru-node.env 2>/dev/null
echo "@@@CLIENTS"
jq -r '.inbounds[]? | select(.tag=="vless-in") | .settings.clients[]? | "\(.email)\t\(.id)"' /usr/local/etc/xray/config.json 2>/dev/null
echo "@@@QUOTAS"
cat /var/lib/vpn-quota/quotas.json 2>/dev/null
echo "@@@STATE"
cat /var/lib/vpn-quota/state.json 2>/dev/null
echo "@@@CUM"
cat /var/lib/vpn-quota/traffic-cumulative.json 2>/dev/null
echo "@@@BLOCKED"
cat /var/lib/vpn-quota/blocked.json 2>/dev/null
echo "@@@ADBLOCK"
jq -r '[.routing.rules[]? | select((.domain // []) | index("geosite:category-ads-all"))] | length' /usr/local/etc/xray/config.json 2>/dev/null
echo "@@@SB"
jq -r '.inbounds[]? | select(.type=="hysteria2") | .users[]? | .name' /etc/sing-box/config.json 2>/dev/null
echo "@@@XRAY"
jq -r '.inbounds[]? | select(.tag=="vless-in") | "\(.port)\t\(.streamSettings.security // "none")\t\(.streamSettings.realitySettings.serverNames[0] // .streamSettings.tlsSettings.serverName // "")"' /usr/local/etc/xray/config.json 2>/dev/null
echo "@@@KEYS"
PRIV=$(jq -r '.inbounds[]? | select(.tag=="vless-in") | .streamSettings.realitySettings.privateKey // empty' /usr/local/etc/xray/config.json 2>/dev/null)
if [ -n "$PRIV" ]; then
  echo "PUB=$(xray x25519 -i "$PRIV" 2>/dev/null | grep -iE 'Password|Public' | awk '{print $NF}')"
  echo "SID=$(jq -r '.inbounds[]? | select(.tag=="vless-in") | .streamSettings.realitySettings.shortIds[0] // empty' /usr/local/etc/xray/config.json 2>/dev/null)"
fi
echo "@@@HY2"
jq -r '.inbounds[]? | select(.type=="hysteria2") | "\(.listen_port)\t\(.tls.server_name // "")"' /etc/sing-box/config.json 2>/dev/null
echo "@@@LASTREBOOT"
cat /var/lib/reboot-schedule/last 2>/dev/null
echo "@@@SERVICES"
echo "xray=$(systemctl is-active xray 2>/dev/null)"
echo "sing-box=$(systemctl is-active sing-box 2>/dev/null)"
echo "@@@END"
"""


def _sections(text: str) -> dict[str, str]:
    out, cur = {}, None
    for line in text.splitlines():
        if line.startswith("@@@"):
            cur = line[3:].strip()
            out[cur] = ""
        elif cur is not None:
            out[cur] += line + "\n"
    return out


def _env(text: str) -> dict[str, str]:
    env = {}
    for line in text.splitlines():
        if "=" in line and not line.strip().startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def read_state(node: Node) -> dict:
    rc, out, err = node.run(STATE_CMD, timeout=60)
    if rc != 0 and not out.strip():
        raise RuntimeError((err or out).strip() or "не удалось прочитать состояние")
    sec = _sections(out)
    env = _env(sec.get("ENV", ""))
    clients = []
    for line in sec.get("CLIENTS", "").splitlines():
        if "\t" in line:
            name, uid = line.split("\t", 1)
            clients.append({"name": name.strip(), "uuid": uid.strip()})
    for name in sec.get("SB", "").splitlines():
        if name.strip():
            clients.append({"name": name.strip(), "uuid": "", "hysteria2": True})
    try:
        quotas = json.loads(sec.get("QUOTAS") or "{}")
    except json.JSONDecodeError:
        quotas = {}
    try:
        used = json.loads(sec.get("STATE") or "{}")
    except json.JSONDecodeError:
        used = {}
    try:
        cum = json.loads(sec.get("CUM") or "{}")
    except json.JSONDecodeError:
        cum = {}
    try:
        blocked = json.loads(sec.get("BLOCKED") or "{}")
    except json.JSONDecodeError:
        blocked = {}
    services = []
    for line in sec.get("SERVICES", "").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            if v.strip() == "active":
                services.append(k)

    # --- параметры входа: сначала из ru-node.env, недостающее — из живого конфига
    xray_line = [ln for ln in sec.get("XRAY", "").splitlines() if ln.strip()]
    if xray_line:
        parts = xray_line[0].split("\t")
        port = parts[0].strip() if len(parts) > 0 else ""
        security = parts[1].strip() if len(parts) > 1 else ""
        sni = parts[2].strip() if len(parts) > 2 else ""
        if port:
            env.setdefault("ENTRY_PORT", port)
        if sni:
            env.setdefault("ENTRY_SNI", sni)
        if security in ("reality", "tls"):
            env.setdefault("ENTRY_TRANSPORT", security)

    for line in sec.get("KEYS", "").splitlines():
        if line.startswith("PUB=") and not env.get("ENTRY_PUB"):
            env["ENTRY_PUB"] = line.split("=", 1)[1].strip()
        if line.startswith("SID=") and not env.get("ENTRY_SID"):
            env["ENTRY_SID"] = line.split("=", 1)[1].strip()

    hy2_line = [ln for ln in sec.get("HY2", "").splitlines() if ln.strip()]
    if hy2_line:
        parts = hy2_line[0].split("\t")
        env["ENTRY_TRANSPORT"] = "hysteria2"
        if len(parts) > 0 and parts[0].strip():
            env["ENTRY_PORT"] = parts[0].strip()
        if len(parts) > 1 and parts[1].strip():
            env["ENTRY_SNI"] = parts[1].strip()

    env.setdefault("ENTRY_IP", node.host)
    env.setdefault("ENTRY_PORT", "443")
    env.setdefault("ENTRY_TRANSPORT",
                   "hysteria2" if any(c.get("hysteria2") for c in clients) else "reality")

    rows = []
    for c in clients:
        name = c["name"]
        q = quotas.get(name, {})
        u = used.get(name, {})
        total_b = int(u.get("total", 0) or 0)
        limit = q.get("gb")
        rows.append({
            "name": name,
            "uuid": c.get("uuid", ""),
            "used_gb": total_b / 1073741824,
            "limit_gb": limit,
            "blocked": bool(q.get("blocked")),
            "hysteria2": bool(c.get("hysteria2")),
        })

    # заблокированные клиенты убраны из конфига: показываем и тех, у кого есть
    # лимит (quotas.json), и тех, у кого лимита не было (blocked.json)
    known = {r["name"] for r in rows}
    for name in sorted(set(quotas) | set(blocked)):
        if name in known:
            continue
        q = quotas.get(name) or {}
        b = blocked.get(name) or {}
        u = used.get(name, {})
        rows.append({
            "name": name,
            "uuid": q.get("id") or b.get("id", ""),
            "used_gb": int(u.get("total", 0) or 0) / 1073741824,
            "limit_gb": q.get("gb"),
            "blocked": True,
            "hysteria2": False,
            "blocked_at": b.get("blocked_at", ""),
        })

    lifetime = (int(cum.get("base_up", 0)) + int(cum.get("base_down", 0))
                + int(cum.get("period_up", 0)) + int(cum.get("period_down", 0)))
    adblock = sec.get("ADBLOCK", "").strip() not in ("", "0", "null")
    return {
        "env": env,
        "transport": env.get("ENTRY_TRANSPORT") or ("hysteria2" if any(c.get("hysteria2") for c in clients) else "reality"),
        "rows": rows,
        "lifetime_bytes": lifetime,
        "services": services,
        "adblock": adblock,
        "last_reboot": sec.get("LASTREBOOT", "").strip(),
    }


# --------------------------------------------------------------------------
#  ссылки
# --------------------------------------------------------------------------
def build_link(env: dict, name: str, uuid: str, password: str = "") -> str:
    transport = env.get("ENTRY_TRANSPORT", "reality")
    ip = env.get("ENTRY_IP", "")
    port = env.get("ENTRY_PORT", "443")
    sni = env.get("ENTRY_SNI", "")
    tag = quote(name)
    if transport == "hysteria2":
        return (f"hysteria2://{password}@{ip}:{port}/?sni={sni}&insecure=1#{tag}")
    if transport == "tls":
        return (f"vless://{uuid}@{ip}:{port}?encryption=none&flow=xtls-rprx-vision"
                f"&security=tls&sni={sni}&allowInsecure=1&type=tcp&headerType=none#{tag}")
    return (f"vless://{uuid}@{ip}:{port}?encryption=none&flow=xtls-rprx-vision"
            f"&security=reality&sni={sni}&fp=chrome&pbk={env.get('ENTRY_PUB','')}"
            f"&sid={env.get('ENTRY_SID','')}&type=tcp&headerType=none#{tag}")


# --------------------------------------------------------------------------
#  клиенты
# --------------------------------------------------------------------------
# xray -test, запущенный от root, создаёт /var/log/xray/error.log владельцем root,
# после чего сервис под пользователем xray не может открыть лог и падает.
LOG_FIX = r"""
install -d -o xray -g xray -m 755 /var/log/xray 2>/dev/null || true
rm -f /var/log/xray/error.log
install -o xray -g xray -m 640 /dev/null /var/log/xray/error.log 2>/dev/null || : > /var/log/xray/error.log
"""

RESTART_XRAY = LOG_FIX + r"""
systemctl restart xray
sleep 1
if ! systemctl is-active --quiet xray; then
  echo "XRAY_START_FAILED"; journalctl -u xray -n 15 --no-pager; exit 1
fi
"""

CREATE_XRAY = r"""
set -e
CFG=/usr/local/etc/xray/config.json
NAME="$RN_NAME"
if jq -e --arg e "$NAME" '.inbounds[]?|select(.tag=="vless-in")|.settings.clients[]?|select(.email==$e)' "$CFG" >/dev/null 2>&1; then
  echo "EXISTS"; exit 0
fi
UUID=$(cat /proc/sys/kernel/random/uuid)
jq --arg i "$UUID" --arg e "$NAME" '.inbounds |= map(if .tag=="vless-in" then .settings.clients += [{id:$i, email:$e, flow:"xtls-rprx-vision"}] else . end)' "$CFG" > /tmp/ratnet-c.json
xray -test -config /tmp/ratnet-c.json >/dev/null 2>&1
@@LOG_FIX@@
mv /tmp/ratnet-c.json "$CFG"
chown xray:xray "$CFG"; chmod 644 "$CFG"
@@RESTART_XRAY@@
jq --arg e "$NAME" 'del(.[$e])' /var/lib/vpn-quota/blocked.json > /tmp/ratnet-b.json 2>/dev/null \
  && mv /tmp/ratnet-b.json /var/lib/vpn-quota/blocked.json || true
echo "UUID=$UUID"
""".replace("@@LOG_FIX@@", LOG_FIX).replace("@@RESTART_XRAY@@", RESTART_XRAY)

ADD_QUOTA = r"""
if [ "$GB" != "0" ]; then
  jq --arg e "$NAME" --arg i "$UUID" --argjson g $GB \
     '.[$e] = {gb:$g, id:$i, flow:"xtls-rprx-vision", blocked:false, warned:false}' \
     /var/lib/vpn-quota/quotas.json > /tmp/ratnet-q.json
  mv /tmp/ratnet-q.json /var/lib/vpn-quota/quotas.json
  chmod 600 /var/lib/vpn-quota/quotas.json
fi
"""

CREATE_HY2 = r"""
set -e
CFG=/etc/sing-box/config.json
NAME="$RN_NAME"
if jq -e --arg n "$NAME" '.inbounds[]?|select(.type=="hysteria2")|.users[]?|select(.name==$n)' "$CFG" >/dev/null 2>&1; then
  echo "EXISTS"; exit 0
fi
PASS=$(openssl rand -hex 16)
jq --arg n "$NAME" --arg p "$PASS" '.inbounds |= map(if .type=="hysteria2" then .users += [{{name:$n,password:$p}}] else . end)' "$CFG" > /tmp/ratnet-s.json
sing-box check -c /tmp/ratnet-s.json >/dev/null 2>&1
mv /tmp/ratnet-s.json "$CFG"
systemctl restart sing-box
echo "PASS=$PASS"
"""

DELETE_USER = r"""
CFG=/usr/local/etc/xray/config.json
NAME="$RN_NAME"
jq --arg e "$NAME" '.inbounds |= map(if .tag=="vless-in" then .settings.clients |= map(select(.email != $e)) else . end)' "$CFG" > /tmp/ratnet-d.json 2>/dev/null || true
if [ -s /tmp/ratnet-d.json ] && xray -test -config /tmp/ratnet-d.json >/dev/null 2>&1; then
  @@LOG_FIX@@
  mv /tmp/ratnet-d.json "$CFG"; chown xray:xray "$CFG"; chmod 644 "$CFG"
  @@RESTART_XRAY@@
fi
jq --arg e "$NAME" 'del(.[$e])' /var/lib/vpn-quota/quotas.json > /tmp/ratnet-q.json 2>/dev/null && mv /tmp/ratnet-q.json /var/lib/vpn-quota/quotas.json
jq --arg e "$NAME" 'del(.[$e])' /var/lib/vpn-quota/state.json > /tmp/ratnet-st.json 2>/dev/null && mv /tmp/ratnet-st.json /var/lib/vpn-quota/state.json
jq --arg e "$NAME" 'del(.[$e])' /var/lib/vpn-quota/blocked.json > /tmp/ratnet-b.json 2>/dev/null && mv /tmp/ratnet-b.json /var/lib/vpn-quota/blocked.json
if [ -f /etc/sing-box/config.json ]; then
  jq --arg n "$NAME" '.inbounds |= map(if .type=="hysteria2" then .users |= map(select(.name != $n)) else . end)' /etc/sing-box/config.json > /tmp/ratnet-s.json 2>/dev/null && \
    sing-box check -c /tmp/ratnet-s.json >/dev/null 2>&1 && mv /tmp/ratnet-s.json /etc/sing-box/config.json && systemctl restart sing-box
fi
echo "deleted"
""".replace("@@LOG_FIX@@", LOG_FIX).replace("@@RESTART_XRAY@@", RESTART_XRAY)


def create_client(node: Node, name: str, gb: float = 0, on_output=None) -> dict:
    name = name.strip()
    if not name:
        raise ValueError("имя не задано")
    state = read_state(node)
    env = state["env"]
    transport = state["transport"]
    if transport == "hysteria2":
        rc, out, err = node.run("RN_NAME=" + shlex.quote(name) + "\n" + CREATE_HY2, timeout=120, on_output=on_output)
        if rc != 0:
            raise RuntimeError((err or out).strip())
        if "EXISTS" in out:
            raise RuntimeError(f"клиент {name} уже есть")
        password = ""
        for line in out.splitlines():
            if line.startswith("PASS="):
                password = line.split("=", 1)[1].strip()
        return {"name": name, "link": build_link(env, name, "", password), "transport": transport}

    rc, out, err = node.run("RN_NAME=" + shlex.quote(name) + "\n" + CREATE_XRAY, timeout=120, on_output=on_output)
    if rc != 0:
        raise RuntimeError((err or out).strip())
    if "EXISTS" in out:
        raise RuntimeError(f"клиент {name} уже есть")
    uuid = ""
    for line in out.splitlines():
        if line.startswith("UUID="):
            uuid = line.split("=", 1)[1].strip()
    if not uuid:
        raise RuntimeError("сервер не вернул UUID")
    gb_val = float(gb or 0)
    if gb_val > 0:
        script = ("NAME=" + shlex.quote(name) + "\nUUID=" + shlex.quote(uuid) + "\n"
                  + "GB=" + str(gb_val) + "\n" + ADD_QUOTA)
        node.run(script, timeout=60, on_output=on_output)
    return {"name": name, "uuid": uuid, "link": build_link(env, name, uuid), "transport": transport}


def link_for(node: Node, name: str) -> str:
    st = read_state(node)
    env = st["env"]
    for row in st["rows"]:
        if row["name"] == name:
            if row["hysteria2"]:
                # пароль клиента Hysteria2 лежит в конфиге sing-box
                rc, out, _ = node.run(
                    "jq -r --arg n %s '.inbounds[]|select(.type==\"hysteria2\")|.users[]|select(.name==$n).password' /etc/sing-box/config.json"
                    % shlex.quote(name), timeout=30)
                return build_link(env, name, "", out.strip())
            return build_link(env, name, row["uuid"])
    raise RuntimeError(f"клиент {name} не найден")


def delete_client(node: Node, name: str, on_output=None) -> None:
    rc, out, err = node.run("RN_NAME=" + shlex.quote(name) + "\n" + DELETE_USER, timeout=120, on_output=on_output)
    if rc != 0:
        raise RuntimeError((err or out).strip())


def reset_quota(node: Node, name: str, on_output=None) -> None:
    rc, out, err = node.run(f"vpn-quota.sh reset {shlex.quote(name)}", timeout=120, on_output=on_output)
    if rc != 0:
        raise RuntimeError((err or out).strip() or "не удалось сбросить")


# --------------------------------------------------------------------------
#  блокировка / разблокировка клиента
# --------------------------------------------------------------------------
def set_client_blocked(node: Node, script_path: str, name: str, blocked: bool, on_output=None) -> str:
    """Убрать клиента из входа (block) или вернуть с прежним UUID (unblock)."""
    remote = "/usr/local/bin/ratnet-client-block.sh"
    node.upload(script_path, remote + ".tmp")
    node.run(f"chmod 755 {remote}.tmp && mv {remote}.tmp {remote}", timeout=60, on_output=on_output)
    action = "block" if blocked else "unblock"
    rc, out, err = node.run(f"{remote} {shlex.quote(name)} {action}", timeout=180, on_output=on_output)
    if rc != 0:
        raise RuntimeError((err or out).strip() or f"не удалось выполнить {action}")
    return out.strip()


# --------------------------------------------------------------------------
#  возврат сервера в исходное состояние
# --------------------------------------------------------------------------
def clean_node(node: Node, script_path: str, role: str, on_output=None,
               dry_run: bool = True, confirm: str = "",
               with_singbox: bool = False, with_ufw: bool = False) -> str:
    """Удалить с сервера всё, что поставил Ratnet VPN (Xray, службы, учёт).

    dry_run=True — только показать список, ничего не меняя.
    Для реального удаления нужен confirm, равный hostname сервера.
    """
    if role not in ("entry", "exit"):
        raise ValueError("role должна быть entry или exit")
    remote = "/usr/local/bin/ratnet-cleanup.sh"
    node.upload(script_path, remote)
    args = ["--role", role]
    if dry_run:
        args.append("--dry-run")
    if confirm:
        args.extend(["--confirm", shlex.quote(confirm)])
    if with_singbox:
        args.append("--with-singbox")
    if with_ufw:
        args.append("--with-ufw")
    rc, out, err = node.run(f"{remote} " + " ".join(args), timeout=1800, on_output=on_output)
    if rc != 0:
        raise RuntimeError((err or out).strip() or f"скрипт очистки завершился с кодом {rc}")
    return out


def cleanup_hostname(dry_output: str) -> str:
    """Достаёт имя сервера из вывода предпросмотра."""
    for line in (dry_output or "").splitlines():
        line = line.strip()
        if line.lower().startswith("хост:"):
            return line.split(":", 1)[1].strip()
    return ""


# --------------------------------------------------------------------------
#  блокировка рекламы
# --------------------------------------------------------------------------
ADBLOCK_ON = r"""
set -e
CFG=/usr/local/etc/xray/config.json
jq 'if (.routing.rules // [] | map((.domain // []) | index("geosite:category-ads-all")) | any) then .
    else .routing.rules = ((.routing.rules // []) | .[0:-1] + [{type:"field", domain:["geosite:category-ads-all"], outboundTag:"block"}] + [.[-1]]) end' "$CFG" > /tmp/ratnet-a.json
xray -test -config /tmp/ratnet-a.json >/dev/null 2>&1
@@LOG_FIX@@
mv /tmp/ratnet-a.json "$CFG"; chown xray:xray "$CFG"; chmod 644 "$CFG"
@@RESTART_XRAY@@
echo "adblock on"
""".replace("@@LOG_FIX@@", LOG_FIX).replace("@@RESTART_XRAY@@", RESTART_XRAY)

ADBLOCK_OFF = r"""
set -e
CFG=/usr/local/etc/xray/config.json
jq 'if .routing then .routing.rules = ((.routing.rules // []) | map(select((.domain // []) | index("geosite:category-ads-all") | not))) else . end' "$CFG" > /tmp/ratnet-a.json
xray -test -config /tmp/ratnet-a.json >/dev/null 2>&1
@@LOG_FIX@@
mv /tmp/ratnet-a.json "$CFG"; chown xray:xray "$CFG"; chmod 644 "$CFG"
@@RESTART_XRAY@@
echo "adblock off"
""".replace("@@LOG_FIX@@", LOG_FIX).replace("@@RESTART_XRAY@@", RESTART_XRAY)


def set_adblock(node: Node, enabled: bool, on_output=None) -> str:
    rc, out, err = node.run(ADBLOCK_ON if enabled else ADBLOCK_OFF, timeout=120, on_output=on_output)
    if rc != 0:
        raise RuntimeError((err or out).strip() or "не удалось изменить блокировку")
    return out.strip()


# --------------------------------------------------------------------------
#  установка / соединение
# --------------------------------------------------------------------------
def deploy_entry(node: Node, script_path: str, transport: str, port: int,
                 adblock: bool, sni: str = "", force: bool = True,
                 on_output=None) -> str:
    node.upload(script_path, "/root/ratnet-01.sh")
    envs = [f"ENTRY_TRANSPORT={shlex.quote(transport)}", f"ENTRY_PORT={int(port)}"]
    if sni:
        envs.append(f"ENTRY_SNI={shlex.quote(sni)}")
    if adblock:
        envs.append("ADBLOCK=1")
    if force:
        envs.append("FORCE=1")
    cmd = " ".join(envs) + " bash /root/ratnet-01.sh 2>&1"
    rc, out, err = node.run(cmd, timeout=1800, on_output=on_output)
    if rc != 0:
        raise RuntimeError((out + err).strip()[-4000:])
    return out


def prepare_exit(node: Node, script_path: str, adblock: bool, tz: str,
                 tag: str = "", reboot: bool = True, on_output=None) -> dict:
    node.upload(script_path, "/root/ratnet-02.sh")
    envs = [f"NODE_TZ={shlex.quote(tz)}", "ADBLOCK=1" if adblock else "ADBLOCK=0",
            "REBOOT_CRON=1" if reboot else "REBOOT_CRON=0"]
    if tag:
        envs.append(f"NODE_TAG={shlex.quote(tag)}")
    rc, out, err = node.run(" ".join(envs) + " bash /root/ratnet-02.sh 2>&1", timeout=1800, on_output=on_output)
    if rc != 0:
        raise RuntimeError((out + err).strip()[-4000:])
    rc2, env_text, _ = node.run("cat /root/foreign-node.env", timeout=30)
    env = _env(env_text)
    if not env.get("JOIN_TOKEN"):
        raise RuntimeError("нода подготовлена, но токен не найден")
    return {"output": out, "env": env, "token": env["JOIN_TOKEN"]}


def join_node(node: Node, script_path: str, token: str, pin_user: str = "",
              on_output=None) -> str:
    node.upload(script_path, "/root/ratnet-03.sh")
    envs = []
    if pin_user:
        envs.append(f"PIN_USER={shlex.quote(pin_user)}")
    cmd = (" ".join(envs) + " " if envs else "") + f"bash /root/ratnet-03.sh {shlex.quote(token)} 2>&1"
    rc, out, err = node.run(cmd, timeout=600, on_output=on_output)
    if rc != 0:
        raise RuntimeError((out + err).strip()[-4000:])
    return out


def decode_token(token: str) -> dict:
    raw = base64.b64decode(token, validate=False, altchars=None)
    return json.loads(raw.decode("utf-8"))
