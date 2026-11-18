#!/usr/bin/env bash
# OmniRoute получает свой MAC в LAN, чтобы Keenetic отправил в xkeen только его.
# Родитель — ethernet. Wi-Fi пропускает один MAC, поэтому при Wi-Fi нужен кабель
# в LAN Keenetic. Сам сервер остаётся на своём текущем подключении.
# Запуск на сервере с контейнером, от root:
#   bash omniroute-egress.sh /путь/docker-compose.yaml
#   bash omniroute-egress.sh down
set -euo pipefail

ENV_FILE=/etc/omniroute-egress.env
NET_NAME=omniroute_egress
SBIN=/usr/local/sbin/omniroute-egress.sh
UNIT_IP=/etc/systemd/system/omniroute-egress-ip.service
UNIT_SNAT=/etc/systemd/system/omniroute-egress.service
UNIT_LINK=/etc/systemd/system/omniroute-egress-link.service
SYS_NET=${SYS_NET:-/sys/class/net}

PREFER_IP=${EGRESS_IP-}
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
[[ -n "$PREFER_IP" ]] && EGRESS_IP=$PREFER_IP
: "${EGRESS_IP:=}"
: "${COMPOSE_FILE:=}"
: "${PROJECT:=}"
: "${LAST_BAK:=}"
: "${NET_NAME:=omniroute_egress}"
: "${PARENT:=}"

c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_0=$'\e[0m'
say()  { echo -e "$*"; }
ok()   { echo -e "${c_g}✓ $*${c_0}"; }
warn() { echo -e "${c_y}! $*${c_0}"; }
err()  { echo -e "${c_r}✗ $*${c_0}" >&2; }

valid_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

find_iface() {
  local best
  IFACE=""
  GATEWAY=""
  IFACE_HOW=""
  best=$(ip -4 route show default | awk '
    $1 == "default" && $2 == "via" {
      gw = $3
      dev = $5
      metric = 0
      for (i = 1; i <= NF; i++) if ($i == "metric") metric = $(i + 1)
      if (chosen == "" || metric + 0 < bestm) {
        chosen = gw " " dev
        bestm = metric + 0
      }
    }
    END { if (chosen != "") print chosen }
  ')
  [[ -n "$best" ]] || return 1
  GATEWAY=${best%% *}
  IFACE=${best##* }
  [[ -n "$GATEWAY" && -n "$IFACE" ]] || return 1
  IFACE_HOW="шлюз $GATEWAY"
}

lan_params() {
  local i src="" cidr=""
  for i in $(seq 1 30); do
    find_iface && break
    sleep 1
  done
  find_iface || { err "нет маршрута по умолчанию"; ip -4 route; return 1; }
  src=$(ip -4 route show default | awk -v gw="$GATEWAY" -v dev="$IFACE" '
    $1=="default" && $3==gw && $5==dev {
      for (i=1;i<=NF;i++) if ($i=="src") { print $(i+1); exit }
    }')
  if [[ -n "$src" ]]; then
    cidr=$(ip -4 -o addr show dev "$IFACE" | awk -v s="$src/" '$4 ~ "^"s {print $4; exit}')
  fi
  if [[ -z "$cidr" ]]; then
    cidr=$(ip -4 -o addr show dev "$IFACE" scope global | awk '{print $4; exit}')
  fi
  [[ -n "$cidr" ]] || { err "на $IFACE нет IPv4-адреса"; return 1; }
  HOST_ADDR=${cidr%%/*}
  SUBNET=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$cidr")
}

pick_ip() {
  lan_params || return 1
  local old="${EGRESS_IP:-}" chosen ip out
  chosen=$(python3 - "$SUBNET" "$GATEWAY" "$HOST_ADDR" "$old" <<'PY'
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1], strict=False)
gw = ipaddress.ip_address(sys.argv[2])
host = ipaddress.ip_address(sys.argv[3])
prefer = sys.argv[4]
def ok(ip):
    return ip in net and ip not in (gw, host, net.network_address, net.broadcast_address)
cands = []
if prefer:
    try:
        cands.append(ipaddress.ip_address(prefer))
    except ValueError:
        pass
if net.prefixlen <= 24:
    parts = str(net.network_address).split(".")
    cands.append(ipaddress.ip_address(".".join(parts[:3] + ["222"])))
last = int(net.num_addresses) - 2
for n in range(last, max(last - 30, 1), -1):
    cands.append(net.network_address + n)
seen = set()
for ip in cands:
    if ip in seen or not ok(ip):
        continue
    seen.add(ip)
    print(ip)
PY
)
  while read -r ip; do
    [[ -n "$ip" ]] || continue
    if command -v arping >/dev/null 2>&1; then
      out=$(arping -D -I "${PARENT:-$IFACE}" -c 2 "$ip" 2>&1 || true)
      if [[ "$out" == *[Rr]eply* ]]; then
        warn "$ip занят"
        continue
      fi
    fi
    EGRESS_IP=$ip
    [[ -n "$old" && "$old" != "$EGRESS_IP" ]] && say "адрес $old не в сети $SUBNET, для OmniRoute выбран $EGRESS_IP"
    OMNI_MAC=$(python3 -c 'p=[int(x) for x in __import__("sys").argv[1].split(".")]; print("02:42:%02x:%02x:%02x:%02x"%tuple(p))' "$EGRESS_IP")
    return 0
  done <<<"$chosen"
  err "нет свободного адреса в $SUBNET"
  return 1
}

cleanup_alias() {
  local ip con
  for ip in 192.168.1.222 ${EGRESS_IP:-}; do
    valid_ip "$ip" || continue
    [[ "$ip" == "${HOST_ADDR:-}" ]] && continue
    ip addr del "$ip/32" dev "$IFACE" 2>/dev/null || true
  done
  command -v nmcli >/dev/null 2>&1 || return 0
  con=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null || true)
  [[ -z "$con" || "$con" == "--" ]] && return 0
  nmcli connection modify "$con" -ipv4.addresses "192.168.1.222/32" 2>/dev/null || true
}

write_env() {
  umask 022
  printf 'EGRESS_IP=%q\nCOMPOSE_FILE=%q\nPROJECT=%q\nLAST_BAK=%q\nNET_NAME=%q\nPARENT=%q\n' \
    "$EGRESS_IP" "$COMPOSE_FILE" "$PROJECT" "$LAST_BAK" "$NET_NAME" "${PARENT:-}" > "$ENV_FILE"
  chmod 644 "$ENV_FILE"
}

is_wifi() {
  [[ -d "$SYS_NET/$1/phy80211" || -d "$SYS_NET/$1/wireless" ]]
}

is_physical_eth() {
  local i=$1 t
  [[ "$i" == lo || "$i" == docker* || "$i" == veth* || "$i" == br-* || "$i" == virbr* ]] && return 1
  is_wifi "$i" && return 1
  [[ -d "$SYS_NET/$i/bridge" ]] && return 1
  [[ -e "$SYS_NET/$i/device" ]] || return 1
  t=$(cat "$SYS_NET/$i/type" 2>/dev/null || echo 0)
  [[ "$t" == 1 ]]
}

choose_parent() {
  local i carrier base addr
  PARENT=""
  ETH_PRESENT=""
  if ! is_wifi "$IFACE"; then
    PARENT=$IFACE
    return 0
  fi
  for base in "$SYS_NET"/*; do
    [[ -e "$base" ]] || continue
    i=$(basename "$base")
    is_physical_eth "$i" || continue
    ETH_PRESENT+="$i "
    carrier=$(cat "$SYS_NET/$i/carrier" 2>/dev/null || echo 0)
    if [[ "$carrier" != 1 ]]; then
      ip link set "$i" up >/dev/null 2>&1 || true
      sleep 1
      carrier=$(cat "$SYS_NET/$i/carrier" 2>/dev/null || echo 0)
    fi
    [[ "$carrier" == 1 ]] || continue
    if [[ -z "$PARENT" ]]; then
      PARENT=$i
    fi
    addr=$(ip -4 -o addr show dev "$i" 2>/dev/null | awk '{print $4; exit}' || true)
    if [[ -n "$addr" && -n "${SUBNET:-}" ]] && python3 -c 'import ipaddress,sys; raise SystemExit(0 if ipaddress.ip_address(sys.argv[1].split("/")[0]) in ipaddress.ip_network(sys.argv[2], strict=False) else 1)' "$addr" "$SUBNET"; then
      PARENT=$i
      break
    fi
  done
  ETH_PRESENT=${ETH_PRESENT% }
  [[ -n "$PARENT" ]]
}

plain_bak() {
  local f
  if [[ -n "${LAST_BAK:-}" && -f "$LAST_BAK" ]] && ! grep -Eq 'omniroute_egress|host_ipv4|macvlan' "$LAST_BAK"; then
    printf '%s\n' "$LAST_BAK"
    return 0
  fi
  for f in "$COMPOSE_FILE".bak.*; do
    [[ -f "$f" ]] || continue
    grep -Eq 'omniroute_egress|host_ipv4|macvlan' "$f" && continue
    printf '%s\n' "$f"
    return 0
  done
  return 1
}

unpatch_compose() {
  python3 - "$COMPOSE_FILE" <<'PY'
import sys
path = sys.argv[1]
lines = [l.rstrip("\r") for l in open(path).read().splitlines()]

def find_service(lines):
    for i, line in enumerate(lines):
        raw = line.split("#", 1)[0].rstrip()
        if raw.startswith(" ") and raw.strip().startswith("omniroute:") and raw.strip().split(":", 1)[0].strip() == "omniroute":
            return i
    for i, line in enumerate(lines):
        if line.split("#", 1)[0].strip() not in (
            "container_name: omniroute",
            'container_name: "omniroute"',
            "container_name: 'omniroute'",
        ):
            continue
        ind = len(line) - len(line.lstrip(" "))
        for j in range(i, -1, -1):
            raw = lines[j].split("#", 1)[0]
            if not raw.strip():
                continue
            jind = len(raw) - len(raw.lstrip(" "))
            if 0 < jind < ind and raw.strip().endswith(":"):
                return j
    return None

def span(lines, idx):
    base = len(lines[idx]) - len(lines[idx].lstrip(" "))
    for j in range(idx + 1, len(lines)):
        raw = lines[j].split("#", 1)[0]
        if raw.strip() and len(raw) - len(raw.lstrip(" ")) <= base:
            return j
    return len(lines)

def key_indent_of(lines, idx, end):
    base = len(lines[idx]) - len(lines[idx].lstrip(" "))
    for line in lines[idx + 1:end]:
        raw = line.split("#", 1)[0]
        if raw.strip():
            ind = len(raw) - len(raw.lstrip(" "))
            if ind > base:
                return ind
    return base + 2

def drop_keys(chunk, indent, names):
    out, i = [], 0
    while i < len(chunk):
        raw = chunk[i].split("#", 1)[0]
        if raw.strip():
            ind = len(raw) - len(raw.lstrip(" "))
            key = raw.strip().split(":", 1)[0].strip()
            if ind == indent and key in names:
                i += 1
                while i < len(chunk):
                    r = chunk[i].split("#", 1)[0]
                    if r.strip() and len(r) - len(r.lstrip(" ")) <= indent:
                        break
                    i += 1
                continue
        out.append(chunk[i])
        i += 1
    return out

svc = find_service(lines)
if svc is None:
    sys.exit("в compose нет сервиса omniroute")
end = span(lines, svc)
indent = key_indent_of(lines, svc, end)
body = drop_keys(lines[svc + 1:end], indent, {"networks", "mac_address"})
if not any(l.split("#", 1)[0].strip().startswith("ports:") and (len(l) - len(l.lstrip(" "))) == indent for l in body):
    pad, pad2 = " " * indent, " " * (indent + 2)
    body = [pad + "ports:", pad2 + '- "20128:20128"'] + body
lines = lines[:svc + 1] + body + lines[end:]

root = None
for i, line in enumerate(lines):
    if line.split("#", 1)[0].strip() == "networks:" and not line.startswith(" "):
        root = i
        break
if root is not None:
    kept = []
    i = root + 1
    while i < len(lines):
        raw = lines[i].split("#", 1)[0]
        if raw.strip():
            ind = len(raw) - len(raw.lstrip(" "))
            if ind == 0:
                break
            if ind <= 2 and raw.strip().split(":", 1)[0].strip() == "egress":
                i += 1
                while i < len(lines):
                    r = lines[i].split("#", 1)[0]
                    if r.strip() and len(r) - len(r.lstrip(" ")) <= 2:
                        break
                    i += 1
                continue
        kept.append(lines[i])
        i += 1
    if any(l.strip() for l in kept):
        lines = lines[:root + 1] + kept + lines[i:]
    else:
        lines = lines[:root] + lines[i:]
        while lines and not lines[-1].strip():
            lines.pop()
open(path, "w").write("\n".join(lines) + "\n")
PY
}

restore_running() {
  local src vol newvol
  [[ -n "${PROJECT:-}" ]] || PROJECT=$(container_project || true)
  vol=$(container_vol || true)
  src=$(plain_bak || true)
  if [[ -n "$src" ]]; then
    cp -a "$src" "$COMPOSE_FILE"
    ok "compose возвращён из $src"
  else
    unpatch_compose
    ok "macvlan убран, порт 20128 снова на сервере"
  fi
  docker rm -f omniroute >/dev/null 2>&1 || true
  docker network rm "$NET_NAME" >/dev/null 2>&1 || true
  dc up -d --force-recreate --no-deps omniroute
  newvol=$(container_vol || true)
  if [[ -n "$vol" && -n "$newvol" && "$newvol" != "$vol" ]]; then
    err "том сменился ($vol → $newvol)"
    return 1
  fi
  [[ -n "$vol" ]] && ok "том данных тот же: $vol"
}

link_unit() {
  local ipb
  ipb=$(command -v ip)
  cat > "$UNIT_LINK" <<EOF
[Unit]
Description=Bring up $PARENT for OmniRoute
DefaultDependencies=no
Before=docker.service
After=network-pre.target

[Service]
Type=oneshot
ExecStart=$ipb link set $PARENT up
RemainAfterExit=yes

[Install]
WantedBy=docker.service
EOF
  systemctl daemon-reload
  systemctl enable --now omniroute-egress-link.service >/dev/null
}

drop_link_unit() {
  systemctl disable --now omniroute-egress-link.service >/dev/null 2>&1 || true
  rm -f "$UNIT_LINK"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

explain_wifi() {
  say "Wi-Fi ($IFACE) пропускает только один MAC. Keenetic видит весь сервер как одно устройство, поэтому отдельный адрес OmniRoute в xkeen не попадает."
  say "OmniRoute снова на обычной сети. Панель — порт 20128 этого сервера."
  if [[ -n "${ETH_PRESENT:-}" ]]; then
    say "Воткни кабель из порта ${ETH_PRESENT} в LAN Keenetic, Wi-Fi не отключай, и запусти скрипт ещё раз."
  else
    say "Отдельного ethernet-порта нет. Нужен USB-Ethernet в LAN Keenetic, затем запусти скрипт ещё раз."
  fi
  say "После этого в xkeen перетаскивается только OmniRoute, сервер остаётся как есть."
}

patch_compose() {
  python3 - "$COMPOSE_FILE" "$EGRESS_IP" "$NET_NAME" "$PARENT" "$SUBNET" "$GATEWAY" "$OMNI_MAC" <<'PY'
import sys
path, ip, net, parent, subnet, gateway, mac = sys.argv[1:]
lines = [l.rstrip("\r") for l in open(path).read().splitlines()]

def find_service(lines):
    for i, line in enumerate(lines):
        raw = line.split("#", 1)[0].rstrip()
        name = raw.strip()
        if name.split(":", 1)[0].strip() == "omniroute" and raw.startswith(" ") and raw.strip().startswith("omniroute:"):
            return i
    for i, line in enumerate(lines):
        if line.split("#", 1)[0].strip() not in (
            "container_name: omniroute",
            'container_name: "omniroute"',
            "container_name: 'omniroute'",
        ):
            continue
        ind = len(line) - len(line.lstrip(" "))
        for j in range(i, -1, -1):
            raw = lines[j].split("#", 1)[0]
            if not raw.strip():
                continue
            jind = len(raw) - len(raw.lstrip(" "))
            if 0 < jind < ind and raw.strip().endswith(":"):
                return j
    return None

def span(lines, idx):
    base = len(lines[idx]) - len(lines[idx].lstrip(" "))
    end = len(lines)
    for j in range(idx + 1, len(lines)):
        raw = lines[j].split("#", 1)[0]
        if not raw.strip():
            continue
        if len(raw) - len(raw.lstrip(" ")) <= base:
            return j
    return end

def key_indent_of(lines, idx, end):
    base = len(lines[idx]) - len(lines[idx].lstrip(" "))
    for line in lines[idx + 1:end]:
        raw = line.split("#", 1)[0]
        if raw.strip():
            ind = len(raw) - len(raw.lstrip(" "))
            if ind > base:
                return ind
    return base + 2

def drop_keys(chunk, indent, names):
    out, i = [], 0
    while i < len(chunk):
        raw = chunk[i].split("#", 1)[0]
        if raw.strip():
            ind = len(raw) - len(raw.lstrip(" "))
            key = raw.strip().split(":", 1)[0].strip()
            if ind == indent and key in names:
                i += 1
                while i < len(chunk):
                    r = chunk[i].split("#", 1)[0]
                    if r.strip() and len(r) - len(r.lstrip(" ")) <= indent:
                        break
                    i += 1
                continue
        out.append(chunk[i])
        i += 1
    return out

svc = find_service(lines)
if svc is None:
    sys.exit("в compose нет сервиса omniroute")
end = span(lines, svc)
indent = key_indent_of(lines, svc, end)
body = drop_keys(lines[svc + 1:end], indent, {"ports", "networks", "mac_address"})
pad, pad2, pad3 = " " * indent, " " * (indent + 2), " " * (indent + 4)
body += [
    pad + "networks:",
    pad2 + "egress:",
    pad3 + "ipv4_address: " + ip,
    pad + 'mac_address: "' + mac + '"',
]
lines = lines[:svc + 1] + body + lines[end:]

block = [
    "  egress:",
    "    name: " + net,
    "    driver: macvlan",
    "    driver_opts:",
    '      parent: "' + parent + '"',
    "    ipam:",
    "      config:",
    "        - subnet: " + subnet,
    "          gateway: " + gateway,
]
root = None
for i, line in enumerate(lines):
    if line.split("#", 1)[0].strip() == "networks:" and not line.startswith(" "):
        root = i
        break
if root is None:
    if lines and lines[-1].strip():
        lines.append("")
    lines += ["networks:"] + block
else:
    out = lines[:root + 1] + block
    i = root + 1
    while i < len(lines):
        raw = lines[i].split("#", 1)[0]
        if raw.strip():
            ind = len(raw) - len(raw.lstrip(" "))
            if ind == 0:
                break
            if ind <= 2 and raw.strip().split(":", 1)[0].strip() == "egress":
                i += 1
                while i < len(lines):
                    r = lines[i].split("#", 1)[0]
                    if r.strip() and len(r) - len(r.lstrip(" ")) <= 2:
                        break
                    i += 1
                continue
        out.append(lines[i])
        i += 1
    lines = out + lines[i:]
open(path, "w").write("\n".join(lines) + "\n")
PY
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
  [[ -n "$PROJECT" ]] && args+=(-p "$PROJECT")
  ( cd "$COMPOSE_DIR" && "${cmd[@]}" "${args[@]}" "$@" )
}

ipt_bin() {
  if iptables -t nat -S DOCKER >/dev/null 2>&1; then
    echo iptables
  elif command -v iptables-legacy >/dev/null 2>&1 && iptables-legacy -t nat -S DOCKER >/dev/null 2>&1; then
    echo iptables-legacy
  elif command -v iptables-nft >/dev/null 2>&1 && iptables-nft -t nat -S DOCKER >/dev/null 2>&1; then
    echo iptables-nft
  else
    echo ""
  fi
}

our_rule_args() {
  local bang='!'
  RULE=( -s "$1" "$bang" -o "$2" -m comment --comment omniroute-egress -j SNAT --to-source "$EGRESS_IP" )
}

bridge_of() {
  local id name
  id=$(docker network inspect -f '{{.Id}}' "$NET_NAME")
  name=$(docker network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' "$NET_NAME" 2>/dev/null || true)
  [[ -z "$name" || "$name" == "<no value>" ]] && name="br-${id:0:12}"
  printf '%s' "$name"
}

subnet_of() {
  docker network inspect -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' "$NET_NAME" | awk '/\./ {print; exit}'
}

del_our_rules() {
  local ipt=$1 line noglob=0
  local -a args
  [[ -n "$ipt" ]] || return 0
  [[ $- == *f* ]] || { set -f; noglob=1; }
  while IFS= read -r line; do
    [[ "$line" == *"--comment omniroute-egress"* ]] || continue
    args=()
    read -r -a args <<<"${line/-A /-D }"
    "$ipt" -w 10 -t nat "${args[@]}" || true
  done < <("$ipt" -t nat -S POSTROUTING 2>/dev/null || true)
  [[ $noglob -eq 1 ]] && set +f
}

stop_snat() {
  systemctl disable --now omniroute-egress.service omniroute-egress-ip.service >/dev/null 2>&1 || true
  rm -f "$UNIT_IP" "$UNIT_SNAT"
  systemctl daemon-reload >/dev/null 2>&1 || true
  local ipt
  ipt=$(ipt_bin || true)
  del_our_rules "${ipt:-}"
}

add_ip() { return 0; }
ensure_rule() { stop_snat; }
watch_loop() { exit 0; }

container_vol() {
  docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Type}} {{.Name}} {{.Source}}{{end}}{{end}}' omniroute 2>/dev/null || true
}

container_project() {
  local p
  p=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' omniroute 2>/dev/null || true)
  [[ "$p" == "<no value>" ]] && p=""
  printf '%s' "$p"
}

verify_egress() {
  local pid cip mac
  pid=$(docker inspect -f '{{.State.Pid}}' omniroute 2>/dev/null || echo 0)
  [[ "$pid" =~ ^[1-9] ]] || { err "контейнер omniroute не запущен"; return 1; }
  cip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' omniroute 2>/dev/null || true)
  mac=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.MacAddress}}{{end}}' omniroute 2>/dev/null || true)
  [[ "$cip" == "$EGRESS_IP" ]] || { err "адрес контейнера $cip, ожидался $EGRESS_IP"; return 1; }
  ok "OmniRoute в LAN: $cip  MAC ${mac:-$OMNI_MAC}"
  if timeout 5 nsenter -t "$pid" -n ping -c 1 -W 2 "$GATEWAY" >/dev/null 2>&1; then
    ok "шлюз $GATEWAY отвечает контейнеру"
    return 0
  fi
  err "контейнер не достучался до $GATEWAY"
  return 1
}

cmd_install() {
  [[ $EUID -eq 0 ]] || { err "запусти от root"; exit 1; }
  command -v docker >/dev/null 2>&1 || { err "нет docker"; exit 1; }
  command -v python3 >/dev/null 2>&1 || { err "нужен python3"; exit 1; }
  [[ -f "$COMPOSE_FILE" ]] || { err "нет файла compose: $COMPOSE_FILE"; exit 1; }
  COMPOSE_FILE=$(readlink -f "$COMPOSE_FILE")
  COMPOSE_DIR=$(dirname "$COMPOSE_FILE")

  stop_snat
  local tmp
  tmp=$(mktemp)
  cp "$BASH_SOURCE" "$tmp"
  install -m 0755 "$tmp" "$SBIN"
  rm -f "$tmp"

  lan_params || exit 1
  cleanup_alias
  local vol proj
  proj=$(container_project || true)
  [[ -n "$proj" ]] && PROJECT=$proj
  vol=$(container_vol || true)

  if ! choose_parent; then
    restore_running || true
    explain_wifi
    exit 1
  fi
  pick_ip
  valid_ip "$EGRESS_IP" || { err "некорректный IP $EGRESS_IP"; exit 1; }
  ip link set "$PARENT" up
  if [[ "$PARENT" == "$IFACE" ]]; then
    ok "шлюз $GATEWAY на $PARENT, OmniRoute: $EGRESS_IP  MAC $OMNI_MAC"
  else
    ok "сервер остаётся на $IFACE. Кабель $PARENT: OmniRoute $EGRESS_IP  MAC $OMNI_MAC"
  fi

  local newbak prev_bak
  prev_bak=${LAST_BAK:-}
  newbak="${COMPOSE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$COMPOSE_FILE" "$newbak"
  if ! grep -Eq 'omniroute_egress|com.docker.network.host_ipv4' "$COMPOSE_FILE"; then
    LAST_BAK=$newbak
  elif [[ -z "$prev_bak" || ! -f "$prev_bak" ]] || grep -Eq 'omniroute_egress|com.docker.network.host_ipv4' "$prev_bak"; then
    LAST_BAK=$newbak
  else
    LAST_BAK=$prev_bak
  fi
  patch_compose
  if ! dc config >/dev/null; then
    cp -a "$newbak" "$COMPOSE_FILE"
    err "compose не принимается, файл возвращён из $newbak"
    exit 1
  fi
  ok "compose обновлён, копия $newbak"

  docker rm -f omniroute >/dev/null 2>&1 || true
  docker network rm "$NET_NAME" >/dev/null 2>&1 || true
  if ! dc up -d --force-recreate --no-deps omniroute; then
    warn "не поднялся — возвращаю обычную сеть"
    restore_running || true
    exit 1
  fi

  local newvol
  newvol=$(container_vol || true)
  if [[ -n "$vol" && -n "$newvol" && "$newvol" != "$vol" ]]; then
    err "том сменился ($vol → $newvol), откатываю"
    cp -a "$newbak" "$COMPOSE_FILE"
    docker rm -f omniroute >/dev/null 2>&1 || true
    docker network rm "$NET_NAME" >/dev/null 2>&1 || true
    dc up -d --force-recreate --no-deps omniroute || true
    exit 1
  fi
  [[ -n "$vol" ]] && ok "том данных тот же: $vol"

  write_env
  if [[ "$PARENT" != "$IFACE" ]]; then
    link_unit || true
  fi
  if ! verify_egress; then
    warn "шлюз $GATEWAY не ответил через $PARENT. Кабель должен быть в LAN этого Keenetic."
    drop_link_unit
    restore_running || true
    say "OmniRoute снова на обычной сети. Панель — порт 20128 этого сервера."
    exit 1
  fi

  local pmac=""
  pmac=$(cat "$SYS_NET/$PARENT/address" 2>/dev/null || true)
  say "Панель: http://${EGRESS_IP}:20128 — с другого устройства в LAN, не с самого сервера."
  say "Keenetic → Приоритеты подключений → Показать все объекты."
  say "В xkeen перетащи только $EGRESS_IP ($OMNI_MAC)."
  if [[ "$PARENT" != "$IFACE" ]]; then
    say "Сервер не трогай, его интернет по-прежнему $IFACE. Не перетаскивай и порт $PARENT${pmac:+ ($pmac)}."
  else
    say "Сервер не трогай."
  fi
  say "На вкладке «Политики доступа в интернет» у xkeen нужное подключение должно быть первым."
  say "Снять: bash $SBIN down"
}

cmd_down() {
  [[ $EUID -eq 0 ]] || { err "запусти от root"; exit 1; }
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
  systemctl disable --now omniroute-egress.service omniroute-egress-ip.service >/dev/null 2>&1 || true
  rm -f "$UNIT_IP" "$UNIT_SNAT"
  drop_link_unit
  local ipt
  ipt=$(ipt_bin || true)
  del_our_rules "${ipt:-}"
  if [[ -n "${COMPOSE_FILE:-}" && -f "$COMPOSE_FILE" ]]; then
    COMPOSE_DIR=$(dirname "$COMPOSE_FILE")
    restore_running
  fi
  IFACE=""
  find_iface || true
  if [[ -n "${IFACE:-}" ]] && valid_ip "${EGRESS_IP:-}"; then
    ip addr del "${EGRESS_IP}/32" dev "$IFACE" 2>/dev/null || true
    if command -v nmcli >/dev/null 2>&1; then
      local con
      con=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null || true)
      [[ -n "$con" && "$con" != "--" ]] && nmcli connection modify "$con" -ipv4.addresses "${EGRESS_IP}/32" 2>/dev/null || true
    fi
  fi
  ok "OmniRoute возвращён на сеть сервера, старый адрес с интерфейса снят"
}

resolve_compose() {
  local arg=${1:-}
  if [[ -n "$arg" && -f "$arg" ]]; then
    COMPOSE_FILE=$arg
    return 0
  fi
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
    add-ip|ensure|watch) exit 0 ;;
    down) cmd_down ;;
    install)
      resolve_compose "${2:-}" || { err "укажи путь к docker-compose.yaml"; exit 1; }
      cmd_install
      ;;
    *)
      if [[ -f "$cmd" ]]; then
        resolve_compose "$cmd"
        cmd_install
      else
        err "неизвестная команда: $cmd"
        exit 1
      fi
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
