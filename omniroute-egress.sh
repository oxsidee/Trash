#!/usr/bin/env bash
# Только OmniRoute ходит через подписку 3x-ui. Остальной сервер не трогается.
# Панель остаётся на порту 20128 этого сервера.
# Запуск из папки с compose, от root:
#   sudo XRAY_SUB='https://панель:2096/sub/....' bash omniroute-egress.sh
#   bash omniroute-egress.sh down
set -euo pipefail

ENV_FILE=/etc/omniroute-egress.env
VPN_DIR=/etc/omniroute-vpn
SBIN=/usr/local/sbin/omniroute-egress.sh
UNIT_REFRESH=/etc/systemd/system/omniroute-xray-refresh.service
TIMER_REFRESH=/etc/systemd/system/omniroute-xray-refresh.timer
UNIT_IP=/etc/systemd/system/omniroute-egress-ip.service
UNIT_SNAT=/etc/systemd/system/omniroute-egress.service
UNIT_LINK=/etc/systemd/system/omniroute-egress-link.service
NET_NAME=omniroute_vpn
XRAY_IMAGE=metacubex/mihomo:latest
PROXY_URL=http://omniroute-xray:7890

user_sub=${XRAY_SUB-}
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
[[ -n "$user_sub" ]] && XRAY_SUB=$user_sub
: "${XRAY_SUB:=}"
: "${COMPOSE_FILE:=}"
: "${PROJECT:=}"
: "${LAST_BAK:=}"

c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_0=$'\e[0m'
say()  { echo -e "$*"; }
ok()   { echo -e "${c_g}✓ $*${c_0}"; }
warn() { echo -e "${c_y}! $*${c_0}"; }
err()  { echo -e "${c_r}✗ $*${c_0}" >&2; }

write_env() {
  umask 077
  printf 'XRAY_SUB=%q\nCOMPOSE_FILE=%q\nPROJECT=%q\nLAST_BAK=%q\n' \
    "$XRAY_SUB" "$COMPOSE_FILE" "$PROJECT" "$LAST_BAK" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

stop_old_units() {
  systemctl disable --now omniroute-egress.service omniroute-egress-ip.service omniroute-egress-link.service >/dev/null 2>&1 || true
  rm -f "$UNIT_IP" "$UNIT_SNAT" "$UNIT_LINK"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

dc() {
  local -a cmd
  if docker compose version >/dev/null 2>&1; then
    cmd=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    cmd=(docker-compose)
  else
    err "нет docker compose"
    return 1
  fi
  local -a args=(-f "$COMPOSE_FILE")
  [[ -n "${PROJECT:-}" ]] && args+=(-p "$PROJECT")
  ( cd "$COMPOSE_DIR" && "${cmd[@]}" "${args[@]}" "$@" )
}

container_vol() {
  docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Type}} {{.Name}} {{.Source}}{{end}}{{end}}' omniroute 2>/dev/null || true
}

container_project() {
  local p
  p=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' omniroute 2>/dev/null || true)
  [[ "$p" == "<no value>" ]] && p=""
  printf '%s' "$p"
}

fetch_provider() {
  install -d -m 700 "$VPN_DIR"
  local info rc
  info=$(python3 - "$XRAY_SUB" "$VPN_DIR/provider.yaml" "$VPN_DIR/config.yaml" <<'PY'
import base64, re, ssl, sys, urllib.request
url, provider_path, config_path = sys.argv[1:]

def candidates(url):
    if not url.startswith(("http://", "https://")):
        return [url]
    out = [url]
    for src, dst in (("/sub/", "/clash/"), ("/sub/", "/mihomo/"), ("/json/", "/clash/"), ("/json/", "/sub/")):
        if src in url:
            nxt = url.replace(src, dst, 1)
            if nxt not in out:
                out.append(nxt)
    return out

def fetch(url):
    req = urllib.request.Request(url, headers={
        "User-Agent": "mihomo",
        "Accept": "application/yaml, application/octet-stream, */*;q=0.1",
    })
    try:
        with urllib.request.urlopen(req, timeout=25, context=ssl.create_default_context()) as resp:
            return resp.read(2_000_000), False
    except ssl.SSLError:
        with urllib.request.urlopen(req, timeout=25, context=ssl._create_unverified_context()) as resp:
            return resp.read(2_000_000), True

def classify(body):
    text = body.decode("utf-8", "replace")
    head = text[:600].lstrip().lower()
    if head.startswith("<!doctype") or head.startswith("<html") or "<html" in head[:200]:
        return None
    names = re.findall(r"(?m)^[ \t]*-[ \t]*name:", text)
    if re.search(r"(?m)^proxies:\s*$", text) and names:
        return ("yaml", len(names))
    raw = text.strip()
    try:
        decoded = base64.b64decode(raw, validate=False).decode("utf-8", "replace")
    except Exception:
        decoded = ""
    blob = decoded if "://" in decoded else text
    links = [ln for ln in blob.splitlines() if "://" in ln]
    if links and not raw.startswith("{") and not raw.startswith("["):
        return ("links", len(links))
    return None

body = None
kind = None
count = 0
unverified = False
last_err = None
for cand in candidates(url):
    try:
        data, unverified = fetch(cand)
    except Exception as exc:
        last_err = exc
        continue
    got = classify(data)
    if not got:
        continue
    body, (kind, count) = data, got
    break
if body is None:
    sys.stderr.write("подписка не разобралась. Нужна ссылка 3x-ui (/sub/..., /clash/...).\n")
    if last_err:
        sys.stderr.write(str(last_err) + "\n")
    sys.exit(2)
if count < 1:
    sys.stderr.write("в подписке нет узлов\n")
    sys.exit(2)
open(provider_path, "wb").write(body if body.endswith(b"\n") else body + b"\n")
open(config_path, "w").write("""mixed-port: 7890
allow-lan: true
bind-address: "*"
mode: rule
log-level: info
ipv6: false
find-process-mode: off
geo-auto-update: false
profile:
  store-selected: false
  store-fake-ip: false
dns:
  enable: true
  ipv6: false
  enhanced-mode: normal
  nameserver:
    - 1.1.1.1
    - 8.8.8.8
proxy-providers:
  xui:
    type: file
    path: ./provider.yaml
    health-check:
      enable: true
      interval: 300
      url: https://www.gstatic.com/generate_204
proxy-groups:
  - name: VPN
    type: url-test
    use:
      - xui
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
rules:
  - MATCH,VPN
""")
print(f"{kind} {count} {int(unverified)}")
PY
)
  rc=$?
  [[ $rc -eq 0 ]] || return "$rc"
  chmod 600 "$VPN_DIR/provider.yaml" "$VPN_DIR/config.yaml" || true
  printf '%s\n' "$info"
}

apply_compose() {
  python3 - "$COMPOSE_FILE" "$XRAY_IMAGE" "$PROXY_URL" "$VPN_DIR" <<'PY'
import sys
path, image, proxy, vpn_dir = sys.argv[1:]
lines = [l.rstrip("\r") for l in open(path).read().splitlines()]

def raw_of(line):
    return line.split("#", 1)[0]

def indent_of(line):
    raw = raw_of(line)
    if not raw.strip():
        return None
    return len(raw) - len(raw.lstrip(" "))

def find_omni(lines):
    for i, line in enumerate(lines):
        raw = raw_of(line).rstrip()
        if raw.startswith(" ") and raw.strip().startswith("omniroute:") and raw.strip().split(":", 1)[0].strip() == "omniroute":
            return i
    for i, line in enumerate(lines):
        if raw_of(line).strip() not in (
            "container_name: omniroute",
            'container_name: "omniroute"',
            "container_name: 'omniroute'",
        ):
            continue
        ind = indent_of(line)
        for j in range(i, -1, -1):
            raw = raw_of(lines[j])
            jind = indent_of(lines[j])
            if jind is None:
                continue
            if 0 < jind < ind and raw.strip().endswith(":"):
                return j
    return None

def span(lines, idx):
    base = indent_of(lines[idx])
    for j in range(idx + 1, len(lines)):
        ind = indent_of(lines[j])
        if ind is not None and ind <= base:
            return j
    return len(lines)

def key_indent(lines, idx, end):
    base = indent_of(lines[idx])
    for line in lines[idx + 1:end]:
        ind = indent_of(line)
        if ind is not None and ind > base:
            return ind
    return base + 2

def drop_keys(chunk, indent, names):
    out, i = [], 0
    while i < len(chunk):
        ind = indent_of(chunk[i])
        if ind == indent:
            key = raw_of(chunk[i]).strip().split(":", 1)[0].strip()
            if key in names:
                i += 1
                while i < len(chunk):
                    ind2 = indent_of(chunk[i])
                    if ind2 is not None and ind2 <= indent:
                        break
                    i += 1
                continue
        out.append(chunk[i])
        i += 1
    return out

def drop_named_block(lines, name, indent):
    out, i = [], 0
    while i < len(lines):
        ind = indent_of(lines[i])
        key = raw_of(lines[i]).strip().split(":", 1)[0].strip() if raw_of(lines[i]).strip() else ""
        if ind == indent and key == name:
            i += 1
            while i < len(lines):
                ind2 = indent_of(lines[i])
                if ind2 is not None and ind2 <= indent:
                    break
                i += 1
            continue
        out.append(lines[i])
        i += 1
    return out

svc = find_omni(lines)
if svc is None:
    sys.exit("в compose нет сервиса omniroute")
end = span(lines, svc)
base = indent_of(lines[svc])
kind = key_indent(lines, svc, end)
body = drop_keys(lines[svc + 1:end], kind, {"mac_address", "networks"})
if not any(raw_of(l).strip().startswith("ports:") and indent_of(l) == kind for l in body):
    body = [" " * kind + "ports:", " " * (kind + 2) + '- "20128:20128"'] + body

proxy_vars = [
    ("HTTP_PROXY", proxy),
    ("HTTPS_PROXY", proxy),
    ("ALL_PROXY", "socks5://omniroute-xray:7890"),
    ("NO_PROXY", "localhost,127.0.0.1"),
    ("ENABLE_SOCKS5_PROXY", "true"),
    ("NODE_USE_ENV_PROXY", "1"),
]
names = {k for k, _ in proxy_vars}

def is_env_key(text, key):
    s = text.strip()
    if s.startswith("- "):
        s = s[2:].strip().strip("'\"")
    return s.startswith(key + "=") or s.startswith(key + ":")

env_at = None
for i, line in enumerate(body):
    if indent_of(line) == kind and raw_of(line).strip() == "environment:":
        env_at = i
        break
if env_at is None:
    env_body = [" " * kind + "environment:"]
    env_body += [" " * (kind + 2) + f'{k}: "{v}"' for k, v in proxy_vars]
    body = env_body + body
else:
    j = env_at + 1
    children = []
    while j < len(body):
        ind = indent_of(body[j])
        if ind is not None and ind <= kind:
            break
        children.append(body[j])
        j += 1
    kept = []
    list_mode = any(raw_of(c).strip().startswith("- ") for c in children)
    child_indent = kind + 2
    for c in children:
        ind = indent_of(c)
        if ind is not None and ind > kind:
            child_indent = ind
            break
    for c in children:
        text = raw_of(c).strip()
        if any(is_env_key(text, k) for k in names):
            continue
        kept.append(c)
    if list_mode:
        extra = [" " * child_indent + f"- {k}={v}" for k, v in proxy_vars]
    else:
        extra = [" " * child_indent + f'{k}: "{v}"' for k, v in proxy_vars]
    body = body[:env_at + 1] + kept + extra + body[j:]

dep_at = None
for i, line in enumerate(body):
    if indent_of(line) == kind and raw_of(line).strip() == "depends_on:":
        dep_at = i
        break
if dep_at is None:
    body += [" " * kind + "depends_on:", " " * (kind + 2) + "- omniroute-xray"]
else:
    window = "\n".join(body[dep_at:dep_at + 8])
    if "omniroute-xray" not in window:
        body.insert(dep_at + 1, " " * (kind + 2) + "- omniroute-xray")

lines = lines[:svc + 1] + body + lines[end:]
lines = drop_named_block(lines, "omniroute-xray", base)
end = span(lines, svc)
xray = [
    " " * base + "omniroute-xray:",
    " " * kind + "image: " + image,
    " " * kind + "container_name: omniroute-xray",
    " " * kind + "restart: unless-stopped",
    " " * kind + "volumes:",
    " " * (kind + 2) + "- " + vpn_dir + ":/root/.config/mihomo",
    " " * kind + "networks:",
    " " * (kind + 2) + "- vpn",
]
lines = lines[:end] + xray + lines[end:]

# service networks: default (порты панели) + vpn (только до прокси)
# inserted above by replacing networks; add the omniroute networks now
# re-find omni after edits
svc = find_omni(lines)
end = span(lines, svc)
kind = key_indent(lines, svc, end)
body = lines[svc + 1:end]
while body and not raw_of(body[-1]).strip():
    body.pop()
if not any(indent_of(l) == kind and raw_of(l).strip() == "networks:" for l in body):
    body += [
        " " * kind + "networks:",
        " " * (kind + 2) + "- default",
        " " * (kind + 2) + "- vpn",
    ]
lines = lines[:svc + 1] + body + lines[end:]

def drop_root_net(lines, name):
    root = None
    for i, line in enumerate(lines):
        if raw_of(line).strip() == "networks:" and indent_of(line) == 0:
            root = i
            break
    if root is None:
        return lines
    out = lines[:root + 1]
    i = root + 1
    while i < len(lines):
        ind = indent_of(lines[i])
        if ind == 0:
            break
        key = raw_of(lines[i]).strip().split(":", 1)[0].strip() if raw_of(lines[i]).strip() else ""
        if ind is not None and ind <= 2 and key == name:
            i += 1
            while i < len(lines):
                ind2 = indent_of(lines[i])
                if ind2 is not None and ind2 <= 2:
                    break
                i += 1
            continue
        out.append(lines[i])
        i += 1
    return out + lines[i:]

lines = drop_root_net(lines, "egress")
lines = drop_root_net(lines, "vpn")
vpn_block = [
    "  vpn:",
    "    name: omniroute_vpn",
]
root = None
for i, line in enumerate(lines):
    if raw_of(line).strip() == "networks:" and indent_of(line) == 0:
        root = i
        break
has_default = False
if root is not None:
    for line in lines[root + 1:]:
        ind = indent_of(line)
        if ind == 0:
            break
        key = raw_of(line).strip().split(":", 1)[0].strip() if raw_of(line).strip() else ""
        if ind == 2 and key == "default":
            has_default = True
if not has_default:
    vpn_block.append("  default:")
if root is None:
    if lines and lines[-1].strip():
        lines.append("")
    lines += ["networks:"] + vpn_block
else:
    lines = lines[:root + 1] + vpn_block + lines[root + 1:]

open(path, "w").write("\n".join(lines).rstrip() + "\n")
PY
}

strip_vpn_compose() {
  python3 - "$COMPOSE_FILE" <<'PY'
import sys
path = sys.argv[1]
lines = [l.rstrip("\r") for l in open(path).read().splitlines()]

def raw_of(line):
    return line.split("#", 1)[0]

def indent_of(line):
    raw = raw_of(line)
    if not raw.strip():
        return None
    return len(raw) - len(raw.lstrip(" "))

def drop_named(lines, name, indent):
    out, i = [], 0
    while i < len(lines):
        ind = indent_of(lines[i])
        key = raw_of(lines[i]).strip().split(":", 1)[0].strip() if raw_of(lines[i]).strip() else ""
        if ind == indent and key == name:
            i += 1
            while i < len(lines):
                ind2 = indent_of(lines[i])
                if ind2 is not None and ind2 <= indent:
                    break
                i += 1
            continue
        out.append(lines[i])
        i += 1
    return out

lines = drop_named(lines, "omniroute-xray", 2)
# drop proxy env lines and vpn network entries, keep the rest of the service
keys = ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "ENABLE_SOCKS5_PROXY", "NODE_USE_ENV_PROXY")
out = []
for line in lines:
    text = raw_of(line).strip()
    item = text[2:].strip() if text.startswith("- ") else text
    item = item.strip("'\"")
    if any(item.startswith(k + "=") or item.startswith(k + ":") for k in keys):
        continue
    if text in ("- vpn", "- omniroute-xray"):
        continue
    out.append(line)
lines = out
lines = drop_named(lines, "vpn", 2)
# пустой depends_on после удаления xray
cleaned_dep, i = [], 0
while i < len(lines):
    if raw_of(lines[i]).strip() == "depends_on:":
        j = i + 1
        while j < len(lines) and indent_of(lines[j]) is None:
            j += 1
        if j >= len(lines) or indent_of(lines[j]) <= indent_of(lines[i]):
            i = j
            continue
    cleaned_dep.append(lines[i])
    i += 1
lines = cleaned_dep
# drop empty networks: at root
cleaned, i = [], 0
while i < len(lines):
    if raw_of(lines[i]).strip() == "networks:" and indent_of(lines[i]) == 0:
        j = i + 1
        while j < len(lines) and indent_of(lines[j]) is None:
            j += 1
        if j >= len(lines) or indent_of(lines[j]) == 0:
            i = j
            continue
    cleaned.append(lines[i])
    i += 1
open(path, "w").write("\n".join(cleaned).rstrip() + "\n")
PY
}

plain_bak() {
  local f
  if [[ -n "${LAST_BAK:-}" && -f "$LAST_BAK" ]] && ! grep -Eq 'omniroute_egress|omniroute_vpn|host_ipv4|macvlan|omniroute-xray' "$LAST_BAK"; then
    printf '%s\n' "$LAST_BAK"
    return 0
  fi
  for f in "$COMPOSE_FILE".bak.*; do
    [[ -f "$f" ]] || continue
    grep -Eq 'omniroute_egress|omniroute_vpn|host_ipv4|macvlan|omniroute-xray' "$f" && continue
    printf '%s\n' "$f"
    return 0
  done
  return 1
}

remember_plain_backup() {
  local newbak src
  src=$(plain_bak || true)
  if [[ -n "$src" ]]; then
    LAST_BAK=$src
    return 0
  fi
  if ! grep -Eq 'omniroute_egress|omniroute_vpn|host_ipv4|macvlan|omniroute-xray' "$COMPOSE_FILE"; then
    newbak="${COMPOSE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$COMPOSE_FILE" "$newbak"
    LAST_BAK=$newbak
  fi
}

install_timer() {
  cat > "$UNIT_REFRESH" <<EOF
[Unit]
Description=Refresh OmniRoute 3x-ui subscription

[Service]
Type=oneshot
ExecStart=$SBIN refresh
EOF
  cat > "$TIMER_REFRESH" <<EOF
[Unit]
Description=Refresh OmniRoute 3x-ui subscription

[Timer]
OnBootSec=2min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now omniroute-xray-refresh.timer >/dev/null
}

cmd_refresh() {
  [[ -n "${XRAY_SUB:-}" ]] || { err "нет сохранённой ссылки"; exit 1; }
  local info
  info=$(fetch_provider) || return 1
  if docker ps -a --format '{{.Names}}' | grep -qx omniroute-xray; then
    docker restart omniroute-xray >/dev/null
  fi
  ok "подписка обновлена ($info)"
}

cmd_install() {
  [[ $EUID -eq 0 ]] || { err "запусти от root"; exit 1; }
  command -v docker >/dev/null 2>&1 || { err "нет docker"; exit 1; }
  command -v python3 >/dev/null 2>&1 || { err "нужен python3"; exit 1; }
  [[ -n "${XRAY_SUB:-}" ]] || {
    err "нужна ссылка подписки 3x-ui"
    say "sudo XRAY_SUB='https://панель:порт/sub/....' bash $SBIN"
    exit 1
  }
  [[ -f "$COMPOSE_FILE" ]] || { err "нет файла compose: $COMPOSE_FILE"; exit 1; }
  COMPOSE_FILE=$(readlink -f "$COMPOSE_FILE")
  COMPOSE_DIR=$(dirname "$COMPOSE_FILE")

  local info
  info=$(fetch_provider) || exit 1
  ok "подписка прочитана: $info"

  stop_old_units
  local proj vol
  proj=$(container_project || true)
  [[ -n "$proj" ]] && PROJECT=$proj
  vol=$(container_vol || true)
  remember_plain_backup

  local newbak
  newbak="${COMPOSE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$COMPOSE_FILE" "$newbak"
  apply_compose
  if ! dc config >/dev/null; then
    cp -a "$newbak" "$COMPOSE_FILE"
    err "compose не принимается, файл возвращён"
    exit 1
  fi

  docker rm -f omniroute omniroute-xray >/dev/null 2>&1 || true
  docker network rm omniroute_egress omniroute_vpn >/dev/null 2>&1 || true
  if ! dc up -d --force-recreate omniroute-xray omniroute; then
    warn "не поднялся — возвращаю прежний compose"
    cp -a "$newbak" "$COMPOSE_FILE"
    docker rm -f omniroute-xray >/dev/null 2>&1 || true
    docker network rm omniroute_vpn >/dev/null 2>&1 || true
    dc up -d --force-recreate --no-deps omniroute || true
    exit 1
  fi
  local newvol
  newvol=$(container_vol || true)
  if [[ -n "$vol" && -n "$newvol" && "$newvol" != "$vol" ]]; then
    err "том сменился ($vol → $newvol), откатываю"
    cp -a "$newbak" "$COMPOSE_FILE"
    docker rm -f omniroute omniroute-xray >/dev/null 2>&1 || true
    docker network rm omniroute_vpn >/dev/null 2>&1 || true
    dc up -d --force-recreate --no-deps omniroute || true
    exit 1
  fi
  [[ -n "$vol" ]] && ok "том данных тот же: $vol"

  local tmp
  tmp=$(mktemp)
  cp "$BASH_SOURCE" "$tmp"
  install -m 0755 "$tmp" "$SBIN"
  rm -f "$tmp"
  write_env
  install_timer || true

  say "Сервер ходит как раньше. Через подписку ходит только OmniRoute."
  say "Панель на порту 20128 этого сервера."
  if docker run --rm --network "$NET_NAME" curlimages/curl:8.11.1 -fsS --max-time 25 -x "$PROXY_URL" https://ifconfig.me/ip > /tmp/omniroute-vpn-ip 2>/dev/null; then
    local vip hip
    vip=$(tr -d '[:space:]' < /tmp/omniroute-vpn-ip)
    hip=$(python3 - <<'PY' || true
import urllib.request
print(urllib.request.urlopen("https://ifconfig.me/ip", timeout=20).read().decode().strip())
PY
)
    ok "IP через подписку: $vip"
    [[ -n "$hip" ]] && say "IP сервера: $hip"
    rm -f /tmp/omniroute-vpn-ip
  else
    warn "прокси не ответил. Логи: docker logs omniroute-xray"
  fi
  say "Снять: bash $SBIN down"
}

cmd_down() {
  [[ $EUID -eq 0 ]] || { err "запусти от root"; exit 1; }
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
  systemctl disable --now omniroute-xray-refresh.timer >/dev/null 2>&1 || true
  rm -f "$UNIT_REFRESH" "$TIMER_REFRESH"
  stop_old_units
  if [[ -n "${COMPOSE_FILE:-}" && -f "$COMPOSE_FILE" ]]; then
    COMPOSE_DIR=$(dirname "$COMPOSE_FILE")
    local src
    src=$(plain_bak || true)
    if [[ -n "$src" ]]; then
      cp -a "$src" "$COMPOSE_FILE"
      ok "compose возвращён из $src"
    else
      strip_vpn_compose
    fi
    docker rm -f omniroute omniroute-xray >/dev/null 2>&1 || true
    docker network rm omniroute_egress omniroute_vpn >/dev/null 2>&1 || true
    dc up -d --force-recreate --no-deps omniroute
  fi
  rm -rf "$VPN_DIR"
  ok "OmniRoute снова без подписки"
}

resolve_compose() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == http://* || "$arg" == https://* ]]; then
      XRAY_SUB=$arg
    elif [[ -f "$arg" ]]; then
      COMPOSE_FILE=$arg
    fi
  done
  if [[ -z "$COMPOSE_FILE" ]]; then
    local cfg
    cfg=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' omniroute 2>/dev/null || true)
    cfg=${cfg%%,*}
    [[ "$cfg" == "<no value>" ]] && cfg=""
    if [[ -n "$cfg" && -f "$cfg" ]]; then
      COMPOSE_FILE=$cfg
      return 0
    fi
    local c
    for c in ./docker-compose.yaml ./docker-compose.yml ./compose.yaml ./compose.yml; do
      [[ -f "$c" ]] && COMPOSE_FILE=$c && return 0
    done
  fi
  [[ -n "$COMPOSE_FILE" && -f "$COMPOSE_FILE" ]]
}

main() {
  local cmd=${1:-install}
  case "$cmd" in
    down) cmd_down ;;
    refresh) cmd_refresh ;;
    install)
      resolve_compose "${@:2}" || { err "укажи путь к docker-compose.yaml"; exit 1; }
      cmd_install
      ;;
    *)
      resolve_compose "$@" || { err "укажи путь к docker-compose.yaml"; exit 1; }
      cmd_install
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
