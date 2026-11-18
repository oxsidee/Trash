#!/usr/bin/env bash
# OmniRoute выходит в сеть с отдельного адреса (по умолчанию 192.168.1.222).
# Интерфейс берётся у текущего шлюза сервера. Панель :20128 не переносится.
# Запуск на сервере с контейнером, от root:
#   bash omniroute-egress.sh /путь/docker-compose.yaml
#   bash omniroute-egress.sh down
set -euo pipefail

ENV_FILE=/etc/omniroute-egress.env
NET_NAME=omniroute_egress
SBIN=/usr/local/sbin/omniroute-egress.sh
UNIT_IP=/etc/systemd/system/omniroute-egress-ip.service
UNIT_SNAT=/etc/systemd/system/omniroute-egress.service

user_egress=${EGRESS_IP-}
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
[[ -n "$user_egress" ]] && EGRESS_IP=$user_egress
: "${EGRESS_IP:=192.168.1.222}"
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

add_ip() {
  local i
  for i in $(seq 1 30); do
    find_iface && break
    sleep 1
  done
  find_iface || { err "нет маршрута по умолчанию"; ip -4 route; return 1; }
  if ! ip -4 -o addr show dev "$IFACE" | awk '{print $4}' | grep -q "^${EGRESS_IP}/"; then
    if command -v arping >/dev/null 2>&1; then
      local out
      out=$(arping -D -I "$IFACE" -c 2 "$EGRESS_IP" 2>&1 || true)
      if [[ "$out" == *[Rr]eply* ]]; then
        err "$EGRESS_IP уже отвечает на ARP через $IFACE — адрес занят"
        return 1
      fi
    fi
  fi
  ip addr replace "${EGRESS_IP}/32" dev "$IFACE"
  if ! ip route get "$GATEWAY" from "$EGRESS_IP" >/dev/null 2>&1; then
    err "ядро не принимает источник $EGRESS_IP на $IFACE"
    return 1
  fi
  command -v arping >/dev/null 2>&1 && arping -c 3 -A -I "$IFACE" "$EGRESS_IP" >/dev/null 2>&1 || true
}

persist_nm() {
  command -v nmcli >/dev/null 2>&1 || return 0
  nmcli -t -f DEVICE device 2>/dev/null | grep -qx "$IFACE" || return 0
  local con have
  con=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null || true)
  [[ -z "$con" || "$con" == "--" ]] && return 0
  have=$(nmcli -g ipv4.addresses connection show "$con" 2>/dev/null | tr ',;' '\n' || true)
  if ! grep -qx "${EGRESS_IP}/32" <<<"$have" && ! grep -qx "$EGRESS_IP" <<<"$have"; then
    nmcli connection modify "$con" +ipv4.addresses "${EGRESS_IP}/32"
    ok "NetworkManager: в профиль «$con» добавлен ${EGRESS_IP}/32"
  fi
}

write_env() {
  umask 022
  printf 'EGRESS_IP=%q\nCOMPOSE_FILE=%q\nPROJECT=%q\nLAST_BAK=%q\nNET_NAME=%q\n' \
    "$EGRESS_IP" "$COMPOSE_FILE" "$PROJECT" "$LAST_BAK" "$NET_NAME" > "$ENV_FILE"
  chmod 644 "$ENV_FILE"
}

patch_compose() {
  python3 - "$COMPOSE_FILE" "$EGRESS_IP" "$NET_NAME" <<'PY'
import sys
path, ip, net = sys.argv[1:]
lines = [l.rstrip("\r") for l in open(path).read().splitlines()]
text = "\n".join(lines)
if "com.docker.network.host_ipv4" in text and net in text:
    out = []
    for line in lines:
        if "com.docker.network.host_ipv4" in line:
            pad = line[:len(line) - len(line.lstrip(" "))]
            line = f'{pad}com.docker.network.host_ipv4: "{ip}"'
        out.append(line)
    open(path, "w").write("\n".join(out) + "\n")
    sys.exit(0)

svc = None
for i, line in enumerate(lines):
    raw = line.split("#", 1)[0].rstrip()
    name = raw.strip()
    if name in ("omniroute:", "omniroute") or name.startswith("omniroute:"):
        if name.split(":", 1)[0].strip() == "omniroute" and raw.startswith(" ") and raw.strip().startswith("omniroute:"):
            svc = i
            break
if svc is None:
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
                svc = j
                break
        break
if svc is None:
    sys.exit("в compose нет сервиса omniroute")
svc_indent = len(lines[svc]) - len(lines[svc].lstrip(" "))
end = len(lines)
for j in range(svc + 1, len(lines)):
    raw = lines[j].split("#", 1)[0]
    if not raw.strip():
        continue
    indent = len(raw) - len(raw.lstrip(" "))
    if indent <= svc_indent:
        end = j
        break
key_indent = svc_indent + 2
for line in lines[svc + 1:end]:
    raw = line.split("#", 1)[0]
    if raw.strip() and not raw.strip().startswith("#"):
        ind = len(raw) - len(raw.lstrip(" "))
        if ind > svc_indent:
            key_indent = ind
            break
item_indent = key_indent + 2
body = lines[svc + 1:end]
has = None
for k, line in enumerate(body):
    if line.split("#", 1)[0].strip() == "networks:":
        has = k
        break
if has is None:
    block = [" " * key_indent + "networks:", " " * item_indent + "- egress"]
    if end > 0 and lines[end - 1].strip():
        block = [""] + block
    lines = lines[:end] + block + ([""] if end < len(lines) and lines[end].strip() else []) + lines[end:]
else:
    if not any(l.split("#", 1)[0].strip() in ("- egress", "-egress") for l in body[has + 1:]):
        lines.insert(svc + 1 + has + 1, " " * item_indent + "- egress")

if not any(l.split("#", 1)[0].strip() == "networks:" and not l.startswith(" ") for l in lines):
    lines += [
        "",
        "networks:",
        "  egress:",
        f"    name: {net}",
        "    driver: bridge",
        "    driver_opts:",
        f'      com.docker.network.host_ipv4: "{ip}"',
    ]
elif f"name: {net}" not in "\n".join(lines):
    for i, line in enumerate(lines):
        if line.split("#", 1)[0].strip() == "networks:" and not line.startswith(" "):
            block = [
                "  egress:",
                f"    name: {net}",
                "    driver: bridge",
                "    driver_opts:",
                f'      com.docker.network.host_ipv4: "{ip}"',
            ]
            lines = lines[:i + 1] + block + lines[i + 1:]
            break
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

ensure_rule() {
  (
    flock -w 20 9
    ensure_rule_locked
  ) 9>/run/omniroute-egress.lock
}

ensure_rule_locked() {
  add_ip || return 1
  local ipt subnet br first
  ipt=$(ipt_bin)
  [[ -n "$ipt" ]] || return 0
  if ! docker network inspect "$NET_NAME" >/dev/null 2>&1; then
    del_our_rules "$ipt"
    return 0
  fi
  subnet=$(subnet_of)
  br=$(bridge_of)
  [[ -n "$subnet" && -n "$br" ]] || return 0
  first=$("$ipt" -t nat -S POSTROUTING 2>/dev/null | awk 'NR==1{print; exit}')
  if [[ "$first" == *"--comment omniroute-egress"* && "$first" == *" $subnet "* && "$first" == *"! -o $br "* && "$first" == *"--to-source $EGRESS_IP"* ]]; then
    return 0
  fi
  del_our_rules "$ipt"
  our_rule_args "$subnet" "$br"
  "$ipt" -w 10 -t nat -I POSTROUTING 1 "${RULE[@]}"
  echo "SNAT $subnet -> $EGRESS_IP (выше правил Docker, мост $br)"
}

install_units() {
  cat > "$UNIT_IP" <<EOF
[Unit]
Description=Address $EGRESS_IP for OmniRoute
After=network-online.target
Wants=network-online.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=$SBIN add-ip

[Install]
WantedBy=docker.service multi-user.target
EOF
  cat > "$UNIT_SNAT" <<EOF
[Unit]
Description=Keep OmniRoute SNAT on $EGRESS_IP
After=docker.service omniroute-egress-ip.service
BindsTo=docker.service

[Service]
Type=simple
ExecStart=$SBIN watch
Restart=on-failure
RestartSec=3

[Install]
WantedBy=docker.service multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now omniroute-egress-ip.service omniroute-egress.service
}

watch_loop() {
  local rc
  while true; do
    ensure_rule || true
    rc=0
    timeout 60 docker events --filter type=network >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 0 || $rc -eq 124 ]] || sleep 5
  done
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

verify_egress() {
  local pid cip line
  pid=$(docker inspect -f '{{.State.Pid}}' omniroute 2>/dev/null || echo 0)
  [[ "$pid" =~ ^[1-9] ]] || { err "контейнер omniroute не запущен"; return 1; }
  cip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' omniroute | awk 'NF{print; exit}')
  timeout 5 nsenter -t "$pid" -n bash -c 'echo >/dev/tcp/1.1.1.1/443' >/dev/null 2>&1 || true
  sleep 0.4
  if [[ -r /proc/net/nf_conntrack ]]; then
    line=$(grep -F "src=${cip} " /proc/net/nf_conntrack | grep 'dport=443' | head -n 1 || true)
    if [[ "$line" == *"dst=${EGRESS_IP}"* ]]; then
      ok "исходящие пакеты контейнера уходят с $EGRESS_IP"
      return 0
    fi
    if [[ -n "$line" ]]; then
      err "соединение есть, но источник не $EGRESS_IP"
      echo "$line" >&2
      return 1
    fi
  fi
  warn "conntrack не подтвердил адрес. Проверка с сервера: tcpdump -ni $IFACE host $EGRESS_IP"
  return 0
}

cmd_install() {
  [[ $EUID -eq 0 ]] || { err "запусти от root"; exit 1; }
  valid_ip "$EGRESS_IP" || { err "некорректный IP $EGRESS_IP"; exit 1; }
  command -v docker >/dev/null 2>&1 || { err "нет docker"; exit 1; }
  command -v python3 >/dev/null 2>&1 || { err "нужен python3"; exit 1; }
  [[ -f "$COMPOSE_FILE" ]] || { err "нет файла compose: $COMPOSE_FILE"; exit 1; }
  COMPOSE_FILE=$(readlink -f "$COMPOSE_FILE")
  COMPOSE_DIR=$(dirname "$COMPOSE_FILE")

  add_ip
  ok "на $IFACE ($IFACE_HOW) добавлен $EGRESS_IP/32"
  persist_nm

  local vol proj
  proj=$(container_project || true)
  [[ -n "$proj" ]] && PROJECT=$proj
  vol=$(container_vol || true)

  local newbak prev_bak
  prev_bak=${LAST_BAK:-}
  newbak="${COMPOSE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$COMPOSE_FILE" "$newbak"
  if ! grep -q 'com.docker.network.host_ipv4' "$COMPOSE_FILE"; then
    LAST_BAK=$newbak
  elif [[ -z "$prev_bak" || ! -f "$prev_bak" ]] || grep -q 'com.docker.network.host_ipv4' "$prev_bak"; then
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
  install_units
  ensure_rule || true
  verify_egress || true

  local snat=""
  snat=$( { iptables-save -t nat 2>/dev/null || true; nft list ruleset 2>/dev/null || true; } | grep -F "$EGRESS_IP" | grep -Ei 'SNAT|snat' | head -n 1 || true)
  if [[ -n "$snat" ]]; then
    ok "правило: $snat"
  else
    warn "SNAT-правило с $EGRESS_IP не видно в iptables/nft. Смотри: journalctl -u omniroute-egress -n 30"
  fi
  say "Панель: порт 20128, как раньше (слушает и $EGRESS_IP)."
  say "В LAN исходящие пакеты OmniRoute идут с $EGRESS_IP. Остальные контейнеры — со своего прежнего адреса."
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
  ok "адрес $EGRESS_IP снят, SNAT убран"
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
    add-ip) add_ip ;;
    ensure) ensure_rule ;;
    watch) watch_loop ;;
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
