#!/usr/bin/env bash
# OmniRoute получает свой MAC и свой адрес в сети текущего шлюза.
# В Keenetic в политику xkeen переносится только это устройство.
# Запуск на сервере с контейнером, от root:
#   bash omniroute-egress.sh /путь/docker-compose.yaml
#   bash omniroute-egress.sh down
set -euo pipefail

ENV_FILE=/etc/omniroute-egress.env
NET_NAME=omniroute_egress
SBIN=/usr/local/sbin/omniroute-egress.sh
UNIT_IP=/etc/systemd/system/omniroute-egress-ip.service
UNIT_SNAT=/etc/systemd/system/omniroute-egress.service

PREFER_IP=${EGRESS_IP-}
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
[[ -n "$PREFER_IP" ]] && EGRESS_IP=$PREFER_IP
: "${EGRESS_IP:=}"
: "${COMPOSE_FILE:=}"
: "${PROJECT:=}"
: "${LAST_BAK:=}"
: "${NET_NAME:=omniroute_egress}"

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
      out=$(arping -D -I "$IFACE" -c 2 "$ip" 2>&1 || true)
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
  printf 'EGRESS_IP=%q\nCOMPOSE_FILE=%q\nPROJECT=%q\nLAST_BAK=%q\nNET_NAME=%q\n' \
    "$EGRESS_IP" "$COMPOSE_FILE" "$PROJECT" "$LAST_BAK" "$NET_NAME" > "$ENV_FILE"
  chmod 644 "$ENV_FILE"
}

patch_compose() {
  python3 - "$COMPOSE_FILE" "$EGRESS_IP" "$NET_NAME" "$IFACE" "$SUBNET" "$GATEWAY" "$OMNI_MAC" <<'PY'
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
  else
    warn "контейнер не достучался до $GATEWAY. Если это виртуалка, гипервизор должен пропускать чужие MAC"
  fi
}

cmd_install() {
  [[ $EUID -eq 0 ]] || { err "запусти от root"; exit 1; }
  command -v docker >/dev/null 2>&1 || { err "нет docker"; exit 1; }
  command -v python3 >/dev/null 2>&1 || { err "нужен python3"; exit 1; }
  [[ -f "$COMPOSE_FILE" ]] || { err "нет файла compose: $COMPOSE_FILE"; exit 1; }
  COMPOSE_FILE=$(readlink -f "$COMPOSE_FILE")
  COMPOSE_DIR=$(dirname "$COMPOSE_FILE")

  stop_snat
  pick_ip
  valid_ip "$EGRESS_IP" || { err "некорректный IP $EGRESS_IP"; exit 1; }
  cleanup_alias
  ok "шлюз $GATEWAY на $IFACE, OmniRoute: $EGRESS_IP  MAC $OMNI_MAC"
  [[ "$IFACE" == wl* || "$IFACE" == wlan* ]] && warn "macvlan на Wi-Fi обычно не работает, нужен ethernet"

  local vol proj
  proj=$(container_project || true)
  [[ -n "$proj" ]] && PROJECT=$proj
  vol=$(container_vol || true)

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
    warn "не поднялся — возвращаю прежний compose"
    cp -a "$newbak" "$COMPOSE_FILE"
    docker network rm "$NET_NAME" >/dev/null 2>&1 || true
    dc up -d --force-recreate --no-deps omniroute || true
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

  local tmp
  tmp=$(mktemp)
  cp "$BASH_SOURCE" "$tmp"
  install -m 0755 "$tmp" "$SBIN"
  rm -f "$tmp"
  write_env
  verify_egress || true

  say "Панель: http://${EGRESS_IP}:20128 — с другого устройства в LAN, не с самого сервера."
  say "Keenetic → Приоритеты подключений → Показать все объекты."
  say "В xkeen перетащи только $EGRESS_IP ($OMNI_MAC). Сервер не трогай."
  say "На вкладке «Политики доступа в интернет» у xkeen нужное подключение должно быть первым."
  say "Снять: bash $SBIN down"
}

cmd_down() {
  [[ $EUID -eq 0 ]] || { err "запусти от root"; exit 1; }
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
  systemctl disable --now omniroute-egress.service omniroute-egress-ip.service >/dev/null 2>&1 || true
  rm -f "$UNIT_IP" "$UNIT_SNAT"
  systemctl daemon-reload || true
  local ipt
  ipt=$(ipt_bin || true)
  del_our_rules "${ipt:-}"
  if [[ -n "${COMPOSE_FILE:-}" && -f "${LAST_BAK:-}" && -f "$COMPOSE_FILE" ]]; then
    COMPOSE_DIR=$(dirname "$COMPOSE_FILE")
    cp -a "$LAST_BAK" "$COMPOSE_FILE"
    docker rm -f omniroute >/dev/null 2>&1 || true
    docker network rm "$NET_NAME" >/dev/null 2>&1 || true
    if ! dc up -d --force-recreate --no-deps omniroute; then
      err "не удалось вернуть контейнер. Адрес $EGRESS_IP оставлен на интерфейсе."
      return 1
    fi
    ok "compose возвращён из $LAST_BAK"
  elif [[ -n "${COMPOSE_FILE:-}" && -f "$COMPOSE_FILE" ]] && grep -q omniroute_egress "$COMPOSE_FILE"; then
    err "нет бэкапа compose, адрес $EGRESS_IP не снимаю — иначе контейнер потеряет маршрут"
    return 1
  fi
  IFACE=""
  find_iface || true
  if [[ -n "${IFACE:-}" ]]; then
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
