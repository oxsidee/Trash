#!/usr/bin/env bash
# VLESS + XHTTP через Yandex Cloud CDN: nginx + certbot + 3x-ui (+ сайт на главной CDN-домена).
# Схема: CDN-домен (CNAME на Yandex CDN) → источник — IP этого сервера. Остальной домен сервер не касается.
# Запуск: bash cdn-vpn-setup.sh             — полная настройка нового сервера (под root, Ubuntu/Debian)
#         bash cdn-vpn-setup.sh backup      — снять бэкап 3x-ui (Postgres или SQLite — авто)
#         bash cdn-vpn-setup.sh lock        — пустить на 443 только Yandex CDN
#         bash cdn-vpn-setup.sh unlock      — снять это ограничение
#         bash cdn-vpn-setup.sh panel-proxy — открыть панель только для внешнего reverse proxy (например, Nginx Proxy Manager)
# Ответы и прогресс сохраняются в /root/.cdn-vpn.env — скрипт можно прервать и запустить снова.

set -u

STATE=/root/.cdn-vpn.env
PANEL_TXT=/root/panel.txt
XRAY_PORT=8080
PANEL_PORT=2053
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_b=$'\e[1;36m'; c_0=$'\e[0m'

say()  { echo -e "$*"; }
ok()   { echo -e "${c_g}✓ $*${c_0}"; }
warn() { echo -e "${c_y}! $*${c_0}"; }
err()  { echo -e "${c_r}✗ $*${c_0}"; }
hdr()  { echo; echo -e "${c_b}════════ Шаг $1. $2 ════════${c_0}"; }
todo() { echo -e "${c_y}▶ СДЕЛАЙ:${c_0} $*"; }

ask() { # ask VAR "вопрос" "по умолчанию"
  local __v="$1" __q="$2" __d="${3:-}" __a
  if [[ -n "$__d" ]]; then read -e -r -p "$__q [$__d]: " __a </dev/tty; else read -e -r -p "$__q: " __a </dev/tty; fi
  __a="${__a//[[:space:]]/}"
  printf -v "$__v" '%s' "${__a:-$__d}"
}
ask_domain() { # ask_domain VAR "вопрос" "по умолчанию" — только латиница, цифры, точки и дефисы
  while true; do
    ask "$@"
    [[ "${!1}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] && return 0
    err "Некорректный домен: '${!1}'. Только латиница, цифры, точки и дефисы (проверь раскладку)."
    printf -v "$1" '%s' ""
  done
}
yes_no() { # yes_no "вопрос" y|n
  local a d="${2:-y}"
  read -r -p "$1 [$( [[ $d == y ]] && echo Y/n || echo y/N )]: " a </dev/tty
  a="${a:-$d}"; [[ "$a" =~ ^[YyДд] ]]
}
pause() { read -r -p "$(echo -e "${c_y}Нажми Enter, когда сделаешь...${c_0}")" _ </dev/tty; }

save() { # save VAR — сохранить переменную в файл состояния
  touch "$STATE"; chmod 600 "$STATE"
  sed -i "/^$1=/d" "$STATE"
  printf '%s=%q\n' "$1" "${!1}" >> "$STATE"
}
done_step() { eval "STEP_$1=1"; save "STEP_$1"; }
is_done()   { local v="STEP_$1"; [[ "${!v:-0}" == 1 ]]; }

run_step() { # run_step N "название" func
  local n="$1" title="$2" fn="$3"
  if is_done "$n"; then
    say "${c_g}Шаг $n ($title) уже выполнен.${c_0}"
    yes_no "Повторить его?" n || return 0
  fi
  hdr "$n" "$title"
  "$fn" && done_step "$n" || { err "Шаг $n не завершён. Исправь проблему и запусти скрипт снова — он продолжит с этого шага."; exit 1; }
}

resolve_chain() { dig +short "$1" @1.1.1.1 2>/dev/null | tr '\n' ' '; }
local_https() { # local_https PATH — запрос к nginx этого сервера по CDN-домену, минуя CDN
  curl -s -o /dev/null --max-time 15 -w '%{http_code}' --resolve "$CDN_DOMAIN:443:127.0.0.1" "https://$CDN_DOMAIN$1"
}
xui_base_path() { # путь панели без слэшей: из x-ui или из panel.txt
  local p
  p=$(/usr/local/x-ui/x-ui setting -show 2>/dev/null | sed -nE 's/^webBasePath:[[:space:]]*//p' | head -n1 | tr -d '\r')
  p="${p#/}"; p="${p%/}"
  if [[ -z "$p" || "$p" == *://* ]]; then
    p=$(awk '/^URL:/{print $2}' $PANEL_TXT 2>/dev/null | sed -E 's#https?://[^/]+/?##; s#/.*##')
    p="${p#/}"; p="${p%/}"
  fi
  [[ "$p" == *://* ]] && p=""
  printf '%s' "$p"
}
panel_path() { xui_base_path; }

# --- 3x-ui backup / restore (Postgres или SQLite) ---

xui_load_env() {
  XUI_DB_TYPE=sqlite; XUI_DB_DSN=
  [[ -f /etc/default/x-ui ]] && . /etc/default/x-ui
  case "${XUI_DB_TYPE:-sqlite}" in
    postgres|postgresql|pg) XUI_DB_TYPE=postgres ;;
    *) XUI_DB_TYPE=sqlite ;;
  esac
}

# разбор postgres://user:pass@host:port/db?...
xui_parse_dsn() {
  local dsn="${1:-}"
  PG_USER=; PG_PASS=; PG_HOST=127.0.0.1; PG_PORT=5432; PG_DB=xui
  [[ "$dsn" =~ ^postgres(ql)?://([^:/@]+):([^@]+)@([^:/]+):([0-9]+)/([^?]+) ]] || return 1
  PG_USER="${BASH_REMATCH[2]}"; PG_PASS="${BASH_REMATCH[3]}"
  PG_HOST="${BASH_REMATCH[4]}"; PG_PORT="${BASH_REMATCH[5]}"; PG_DB="${BASH_REMATCH[6]}"
}

xui_pg_counts() {
  PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -At -c \
    "SELECT (SELECT count(*) FROM inbounds)||' '||(SELECT count(*) FROM users)||' '||(SELECT count(*) FROM clients);" 2>/dev/null
}

xui_sqlite_counts() {
  sqlite3 /etc/x-ui/x-ui.db "SELECT (SELECT count(*) FROM inbounds)||' '||(SELECT count(*) FROM users)||' '||(SELECT count(*) FROM clients);" 2>/dev/null
}

xui_write_env() { # xui_write_env TYPE [DSN]
  umask 077
  if [[ "$1" == postgres ]]; then
    printf 'XUI_DB_TYPE=postgres\nXUI_DB_DSN=%s\n' "$2" > /etc/default/x-ui
  else
    printf 'XUI_DB_TYPE=sqlite\n' > /etc/default/x-ui
  fi
  chmod 600 /etc/default/x-ui
}

xui_ensure_postgres() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql postgresql-client >/dev/null || return 1
  systemctl start postgresql 2>/dev/null || true
  systemctl enable postgresql >/dev/null 2>&1 || true
}

xui_pg_prepare_db() { # создаёт роль/БД из PG_*
  local esc_pass="${PG_PASS//\'/\'\'}"
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c \
    "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${PG_USER}') THEN CREATE ROLE \"${PG_USER}\" LOGIN PASSWORD '${esc_pass}'; ELSE ALTER ROLE \"${PG_USER}\" WITH PASSWORD '${esc_pass}'; END IF; END \$\$;" \
    || return 1
  if ! sudo -u postgres psql -At -c "SELECT 1 FROM pg_database WHERE datname='${PG_DB}'" | grep -q 1; then
    sudo -u postgres psql -c "CREATE DATABASE ${PG_DB} OWNER \"${PG_USER}\";" || return 1
  fi
  sudo -u postgres psql -c "ALTER DATABASE ${PG_DB} OWNER TO \"${PG_USER}\"; GRANT ALL PRIVILEGES ON DATABASE ${PG_DB} TO \"${PG_USER}\";" >/dev/null
  sudo -u postgres psql -d "$PG_DB" -c "GRANT ALL ON SCHEMA public TO \"${PG_USER}\"; ALTER SCHEMA public OWNER TO \"${PG_USER}\";" >/dev/null
}

step_backup() {
  xui_load_env
  local out="/root/3xui-backup-$(date +%F-%H%M).tar.gz" tmp
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/meta"
  if [[ -f /etc/default/x-ui ]]; then cp -a /etc/default/x-ui "$tmp/meta/x-ui.env"; fi
  echo "db_type=$XUI_DB_TYPE" > "$tmp/meta/type.txt"
  echo "created=$(date -Is)" >> "$tmp/meta/type.txt"

  systemctl stop x-ui 2>/dev/null || true
  if [[ "$XUI_DB_TYPE" == postgres ]]; then
    xui_parse_dsn "${XUI_DB_DSN:-}" || { err "Не разобрать XUI_DB_DSN в /etc/default/x-ui"; systemctl start x-ui; return 1; }
    command -v pg_dump >/dev/null || { apt-get install -y -qq postgresql-client >/dev/null; }
    say "Снимаю Postgres-дамп ${PG_DB}@${PG_HOST} ..."
    PGPASSWORD="$PG_PASS" pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -Fc -f "$tmp/xui-pg.dump" \
      || { err "pg_dump не удался"; systemctl start x-ui; return 1; }
    local counts; counts=$(xui_pg_counts || true)
    echo "counts_inbounds_users_clients=$counts" >> "$tmp/meta/type.txt"
    say "В базе: inbounds/users/clients = ${counts:-(не удалось посчитать)}"
    [[ "${counts%% *}" =~ ^[1-9] ]] || warn "Входящих 0 — на новом сервере после restore панель будет пустой"
  else
    command -v sqlite3 >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sqlite3 >/dev/null
    [[ -f /etc/x-ui/x-ui.db ]] || { err "Нет /etc/x-ui/x-ui.db"; systemctl start x-ui; return 1; }
    sqlite3 /etc/x-ui/x-ui.db "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
    local counts; counts=$(xui_sqlite_counts || true)
    echo "counts_inbounds_users_clients=$counts" >> "$tmp/meta/type.txt"
    say "В базе: inbounds/users/clients = ${counts:-(не удалось посчитать)}"
    [[ "${counts%% *}" =~ ^[1-9] ]] || warn "Входящих 0 — если панель на Postgres, бэкапь через неё (XUI_DB_TYPE=postgres)"
    mkdir -p "$tmp/etc"
    cp -a /etc/x-ui "$tmp/etc/"
  fi
  systemctl start x-ui

  tar czf "$out" -C "$tmp" .
  chmod 600 "$out"
  ok "Бэкап: $out ($(du -h "$out" | awk '{print $1}'))"
  say "Скачать к себе:  ${c_b}scp root@$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo SERVER):$out .${c_0}"
  say "На новый сервер: ${c_b}scp $(basename "$out") root@НОВЫЙ_IP:/root/${c_0}"
  say "Там:              ${c_b}bash cdn-vpn-setup.sh${c_0} → на шаге 3x-ui укажи путь к этому архиву"
}

# определить тип файла бэкапа → postgres|sqlite|""
xui_backup_kind() {
  local f="$1"
  case "$f" in
    *.dump|*.sql) echo postgres; return ;;
    *.db) echo sqlite; return ;;
  esac
  if tar tzf "$f" 2>/dev/null | grep -qE '(^|/)xui-pg\.dump$'; then echo postgres; return; fi
  if tar tzf "$f" 2>/dev/null | grep -qE '(^|/)x-ui\.db$'; then echo sqlite; return; fi
  echo ""
}

xui_restore_postgres() {
  local bk="$1" dump="$bk" envf="" tmp
  command -v pg_restore >/dev/null || xui_ensure_postgres || return 1
  xui_ensure_postgres || return 1

  if [[ "$bk" == *.tar.gz || "$bk" == *.tgz ]]; then
    tmp=$(mktemp -d)
    tar xzf "$bk" -C "$tmp" || { rm -rf "$tmp"; return 1; }
    dump=$(find "$tmp" -name 'xui-pg.dump' | head -n1)
    envf=$(find "$tmp" -name 'x-ui.env' | head -n1)
    [[ -n "$dump" ]] || { err "В архиве нет xui-pg.dump"; rm -rf "$tmp"; return 1; }
  fi

  if [[ -n "$envf" ]]; then
    # shellcheck disable=SC1090
    . "$envf"
    xui_parse_dsn "${XUI_DB_DSN:-}" || {
      PG_USER=xui; PG_PASS=$(openssl rand -hex 12); PG_HOST=127.0.0.1; PG_PORT=5432; PG_DB=xui
      XUI_DB_DSN="postgres://${PG_USER}:${PG_PASS}@127.0.0.1:5432/${PG_DB}?sslmode=disable"
      warn "DSN из бэкапа не разобран — создаю новый пользователя ${PG_USER}"
    }
  else
    xui_load_env
    if [[ "$XUI_DB_TYPE" == postgres ]] && xui_parse_dsn "${XUI_DB_DSN:-}"; then
      ok "Использую DSN из /etc/default/x-ui"
    else
      PG_USER=xui; PG_PASS=$(openssl rand -hex 12); PG_HOST=127.0.0.1; PG_PORT=5432; PG_DB=xui
      XUI_DB_DSN="postgres://${PG_USER}:${PG_PASS}@127.0.0.1:5432/${PG_DB}?sslmode=disable"
      say "Создаю локальный Postgres: пользователь ${PG_USER}, БД ${PG_DB}"
    fi
  fi
  # на новом сервере Postgres всегда localhost
  PG_HOST=127.0.0.1
  XUI_DB_DSN="postgres://${PG_USER}:${PG_PASS}@127.0.0.1:5432/${PG_DB}?sslmode=disable"

  xui_pg_prepare_db || return 1
  say "Восстанавливаю Postgres-дамп..."
  PGPASSWORD="$PG_PASS" pg_restore -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
    --no-owner --clean --if-exists "$dump" >/tmp/xui-pg-restore.log 2>&1 \
    || warn "pg_restore завершился с предупреждениями (часто нормально) — смотри /tmp/xui-pg-restore.log"

  xui_write_env postgres "$XUI_DB_DSN"
  local counts; counts=$(xui_pg_counts || echo "0 0 0")
  say "После restore: inbounds/users/clients = $counts"
  [[ "${counts%% *}" =~ ^[1-9] ]] || { err "В Postgres 0 входящих — дамп пустой или не тот"; [[ -n "${tmp:-}" ]] && rm -rf "$tmp"; return 1; }
  [[ -n "${tmp:-}" ]] && rm -rf "$tmp"
  ok "Postgres восстановлен, /etc/default/x-ui настроен"
  XUI_RESTORE_COUNTS=$counts
}

xui_restore_sqlite() {
  local bk="$1"
  command -v sqlite3 >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sqlite3 >/dev/null
  rm -f /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db-wal /etc/x-ui/x-ui.db-shm
  if [[ "$bk" == *.db ]]; then
    install -D -m 600 "$bk" /etc/x-ui/x-ui.db || return 1
  else
    local tmp; tmp=$(mktemp -d)
    tar xzf "$bk" -C "$tmp" || { rm -rf "$tmp"; return 1; }
    if [[ -d "$tmp/etc/x-ui" ]]; then cp -a "$tmp/etc/x-ui/." /etc/x-ui/
    elif [[ -f "$tmp/x-ui.db" ]]; then install -D -m 600 "$tmp/x-ui.db" /etc/x-ui/x-ui.db
    else
      # старый формат: etc/x-ui в корне архива относительно /
      tar xzf "$bk" -C / etc/x-ui 2>/dev/null || { err "В архиве нет etc/x-ui"; rm -rf "$tmp"; return 1; }
    fi
    rm -rf "$tmp"
  fi
  if [[ -f /etc/x-ui/x-ui.db-wal ]]; then
    sqlite3 /etc/x-ui/x-ui.db "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null \
      || { err "Не удалось применить WAL"; return 1; }
  fi
  [[ -s /etc/x-ui/x-ui.db ]] || { err "Нет /etc/x-ui/x-ui.db после restore"; return 1; }
  xui_write_env sqlite
  local counts; counts=$(xui_sqlite_counts || echo "0 0 0")
  say "После restore: inbounds/users/clients = $counts"
  if [[ ! "${counts%% *}" =~ ^[1-9] ]]; then
    err "В SQLite 0 входящих. Если на старом сервере был Postgres — снимай бэкап так: bash $0 backup"
    return 1
  fi
  ok "SQLite восстановлен"
  XUI_RESTORE_COUNTS=$counts
}

# ---------------------------------------------------------------- шаги

step_params() {
  ask_domain CDN_DOMAIN "CDN-домен (CNAME на Yandex CDN, к нему подключаются клиенты)" "${CDN_DOMAIN:-}"
  [[ -z "$CDN_DOMAIN" ]] && { err "Домен обязателен"; return 1; }
  ask XHTTP_PATH "Путь туннеля (при переезде — тот же, что был)" "${XHTTP_PATH:-/media/hls/live}"
  [[ "$XHTTP_PATH" != /* ]] && XHTTP_PATH="/$XHTTP_PATH"

  say "\nЧто показывать на главной странице https://$CDN_DOMAIN?"
  say "  1) Простую заглушку"
  say "  2) Свой сайт из git-репозитория (запускается в Docker)"
  ask SITE_MODE "Выбор" "${SITE_MODE:-1}"
  if [[ "$SITE_MODE" == 2 ]]; then
    say "Для приватного репозитория укажи URL с токеном: https://ТОКЕН@github.com/user/repo.git"
    ask SITE_REPO "URL репозитория" "${SITE_REPO:-}"
    ask SITE_PORT "На каком порту сайт слушает внутри Docker" "${SITE_PORT:-9999}"
  fi

  SERVER_IP=$(curl -4 -fsS --max-time 10 https://ifconfig.me 2>/dev/null || curl -4 -fsS --max-time 10 https://api.ipify.org)
  ask SERVER_IP "Публичный IPv4 этого сервера" "$SERVER_IP"

  for v in CDN_DOMAIN XHTTP_PATH SITE_MODE SERVER_IP; do save "$v"; done
  [[ "$SITE_MODE" == 2 ]] && { save SITE_REPO; save SITE_PORT; }
  ok "Параметры сохранены в $STATE"
}

step_packages() {
  apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot dnsutils curl python3 openssl git || return 1
  mkdir -p /var/www/html/.well-known/acme-challenge
  [[ -f /var/www/html/index.html ]] || cat > /var/www/html/index.html <<EOF
<!doctype html><html><head><meta charset="utf-8"><title>$CDN_DOMAIN</title></head><body><h1>$CDN_DOMAIN</h1></body></html>
EOF
  if [[ ! -f /etc/letsencrypt/live/$CDN_DOMAIN/fullchain.pem ]]; then
    cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 80 default_server;
    server_name _;
    root /var/www/html;
}
EOF
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
  fi
  rm -f /etc/nginx/sites-enabled/panel
  nginx -t && systemctl restart nginx && systemctl enable nginx >/dev/null 2>&1 || return 1
  ok "nginx установлен"

  say "\nПроверим, что IP сервера не заблокирован в РФ: иначе узлы Yandex CDN не смогут до него достучаться."
  todo "с телефона на МОБИЛЬНОМ интернете БЕЗ VPN открой  http://$SERVER_IP"
  say "  Открылась страница — IP доступен. Бесконечная загрузка или ошибка — IP заблокирован."
  if ! yes_no "Страница открылась?" y; then
    err "IP $SERVER_IP недоступен из РФ. Через CDN работать не будет: смени IP или сервер."
    yes_no "Всё равно продолжить?" n || return 1
  fi
}

step_yc_cert() {
  local sub="${CDN_DOMAIN%%.*}"
  say "Сертификат для ${CDN_DOMAIN} в Yandex Cloud (его CDN показывает клиентам)."
  say "${c_b}Если он уже есть (переезд) — просто нажми Enter.${c_0}"
  todo "1. Зарегистрируйся на console.yandex.cloud и пополни баланс (~300 ₽)."
  todo "2. Certificate Manager → «Добавить сертификат» → «Сертификат от Let's Encrypt»."
  say  "      Имя: ${c_b}cdn-cert${c_0}    Домен: ${c_b}${CDN_DOMAIN}${c_0}    Тип проверки: ${c_b}DNS${c_0}  → «Создать»"
  todo "3. Открой сертификат → «Проверка прав на домены» → у регистратора создай TXT-запись:"
  say  "      Имя: ${c_b}_acme-challenge.${sub}${c_0}   Значение: строка из консоли Яндекса, без кавычек"
  say  "   Выпуск занимает 20–30 минут."
  pause
}

step_cdn() {
  say "${c_b}Если CDN-ресурс для ${CDN_DOMAIN} уже есть (переезд)${c_0} — открой его → «Редактировать»,"
  say "поставь источник / группу с IP ${c_b}${SERVER_IP}${c_0} и сверь настройки ниже. CNAME трогать не нужно."
  say "Проверка, что CDN реально достучался до сервера, будет после выпуска сертификата и настройки nginx."
  todo "1. Certificate Manager: сертификат для ${CDN_DOMAIN} в статусе «Issued»."
  todo "2. Cloud CDN → ресурс (создать или изменить):"
  say  "   Источник: IP ${c_b}${SERVER_IP}${c_0} (один сервер или группа источников с этим IP)"
  say  "   Протокол для источников: ${c_b}HTTPS${c_0}"
  say  "   Задать SNI вручную: ${c_b}вкл${c_0} → Имя SNI-хоста: ${c_b}${CDN_DOMAIN}${c_0}"
  say  "   Заголовок Host: ${c_b}Своё значение${c_0} → ${c_b}${CDN_DOMAIN}${c_0}"
  say  "   Доменное имя: ${c_b}${CDN_DOMAIN}${c_0}"
  say  "   Тип сертификата: ${c_b}Сертификат из Certificate Manager${c_0} (твой cdn-cert)"
  say  "   Перенаправление: ${c_b}выкл${c_0}"
  say  "   Кеширование в CDN: выкл;  Кеширование в браузере: выкл"
  say  "   Разрешённые методы: GET, HEAD, OPTIONS"
  todo "3. CNAME у регистратора: имя ${c_b}${CDN_DOMAIN%%.*}${c_0} → технический домен из консоли (xxxx.gslb.yccdn.ru)"
  pause
  while true; do
    local chain; chain=$(resolve_chain "$CDN_DOMAIN")
    say "  DNS: ${chain:-нет}"
    if [[ "$chain" == *yccdn* ]]; then ok "CNAME указывает на Yandex CDN"; return 0; fi
    warn "CNAME ещё не указывает на Yandex CDN."
    yes_no "Проверить снова через 2 минуты?" y || { yes_no "Продолжить без проверки?" n && return 0 || return 1; }
    sleep 120
  done
}

step_cert() {
  local sub="${CDN_DOMAIN%%.*}"
  if [[ -f /etc/letsencrypt/live/$CDN_DOMAIN/fullchain.pem ]]; then
    ok "Сертификат уже есть: /etc/letsencrypt/live/$CDN_DOMAIN/"
    return 0
  fi
  say "CDN ходит к серверу только по HTTPS — HTTP-проверка Let's Encrypt через CDN не работает (504)."
  say "Выпускаем сертификат через ${c_b}DNS-01${c_0}: certbot покажет TXT-запись, ты добавишь её у регистратора."
  say "Имя то же, что у сертификата Яндекса (${c_b}_acme-challenge.${sub}${c_0}) — несколько TXT на одном имени допустимы."
  say "Старую TXT Яндекса не удаляй. После выпуска нашу TXT можно убрать."
  todo "Сейчас запустится certbot → скопируй значение TXT → добавь у регистратора → подожди 1–2 минуты → нажми Enter в certbot."
  pause
  # certbot сам печатает имя/значение и ждёт Enter на tty
  certbot certonly --manual --preferred-challenges dns \
    --cert-name "$CDN_DOMAIN" -d "$CDN_DOMAIN" \
    --agree-tos --register-unsafely-without-email \
    --deploy-hook "systemctl reload nginx" </dev/tty \
    || { err "certbot не выпустил сертификат. Проверь TXT _acme-challenge.${sub} у регистратора (dig TXT _acme-challenge.${CDN_DOMAIN})."; return 1; }
  ok "Сертификат: /etc/letsencrypt/live/$CDN_DOMAIN/"
}

# После того как CDN ходит к серверу по HTTPS — продление можно делать через webroot (без TXT).
switch_renew_to_webroot() {
  local conf="/etc/letsencrypt/renewal/${CDN_DOMAIN}.conf"
  [[ -f "$conf" ]] || return 0
  sed -i 's/^authenticator = .*/authenticator = webroot/' "$conf"
  if grep -q '^webroot_path' "$conf"; then sed -i 's|^webroot_path = .*|webroot_path = /var/www/html,|' "$conf"
  else sed -i '/^authenticator = webroot/a webroot_path = /var/www/html,' "$conf"
  fi
  sed -i '/^manual_/d' "$conf"
  if ! grep -q '\[\[webroot_map\]\]' "$conf"; then
    printf '\n[[webroot_map]]\n%s = /var/www/html\n' "$CDN_DOMAIN" >> "$conf"
  fi
  ok "Продление сертификата переключено на webroot (через CDN по HTTPS)"
}

verify_cdn_https() {
  say "Проверяем, что CDN достаёт этот сервер по HTTPS (источник ${SERVER_IP}, SNI/Host ${CDN_DOMAIN})..."
  while true; do
    local code; code=$(curl -s -o /dev/null --max-time 20 -w '%{http_code}' "https://$CDN_DOMAIN/")
    say "  https://$CDN_DOMAIN/ → $code"
    if [[ "$code" == 200 ]]; then
      ok "CDN работает"
      switch_renew_to_webroot
      return 0
    fi
    [[ "$code" == 504 ]] && warn "504: CDN не достучался до сервера по HTTPS. Проверь источник ${SERVER_IP}, SNI и Host = ${CDN_DOMAIN}, что nginx слушает 443."
    [[ "$code" == 502 || "$code" == 525 || "$code" == 526 ]] && warn "Ошибка TLS до источника: SNI должен быть ${CDN_DOMAIN}, сертификат на сервере — на этот же домен."
    yes_no "Проверить снова через 2 минуты?" y || { yes_no "Продолжить без проверки?" n && return 0 || return 1; }
    sleep 120
  done
}

step_site() {
  if [[ "$SITE_MODE" != 2 ]]; then ok "Главная страница — заглушка /var/www/html/index.html"; return 0; fi
  command -v docker >/dev/null || { curl -fsSL https://get.docker.com | sh || return 1; }
  if [[ -d /opt/site/.git ]]; then git -C /opt/site pull || return 1
  else git clone "$SITE_REPO" /opt/site || { err "Не удалось клонировать репозиторий. Для приватного нужен URL с токеном."; return 1; }
  fi
  cd /opt/site || return 1
  if [[ -f docker-compose.yml || -f docker-compose.yaml || -f compose.yml || -f compose.yaml ]]; then
    docker compose up -d --build || return 1
    warn "Проверь, что в compose-файле порт опубликован как \"127.0.0.1:${SITE_PORT}:...\", иначе сайт будет доступен и напрямую по IP:${SITE_PORT}."
  elif [[ -f Dockerfile ]]; then
    docker build -t site . && docker rm -f site >/dev/null 2>&1
    docker run -d --name site --restart unless-stopped -p "127.0.0.1:${SITE_PORT}:${SITE_PORT}" site || return 1
  else
    err "В репозитории нет ни docker-compose.yml, ни Dockerfile"; return 1
  fi
  cd - >/dev/null || true
  for _ in $(seq 1 30); do
    curl -fs -o /dev/null "http://127.0.0.1:${SITE_PORT}/" && { ok "Сайт отвечает на 127.0.0.1:${SITE_PORT}"; return 0; }
    sleep 2
  done
  err "Сайт не отвечает на 127.0.0.1:${SITE_PORT}"; return 1
}

step_nginx() {
  local site_loc
  if [[ "$SITE_MODE" == 2 ]]; then
    site_loc="    location / {
        proxy_pass http://127.0.0.1:${SITE_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
    }"
  else
    site_loc="    location / { root /var/www/html; index index.html; }"
  fi
  local crt="/etc/letsencrypt/live/$CDN_DOMAIN"
  local h2_listen="" h2_line="    http2 on;"
  # директива "http2 on" появилась в nginx 1.25.1
  if ! printf '%s\n' "1.25.1" "$(nginx -v 2>&1 | sed -E 's#.*/([0-9.]+).*#\1#')" | sort -V -C; then
    h2_listen=" http2"; h2_line=""
  fi

  ensure_geo
  cat > /etc/nginx/conf.d/xhttp-log.conf <<'EOF'
log_format xhttp '$remote_addr "$request_method $uri" status=$status up=$upstream_status rt=$request_time urt=$upstream_response_time hlen=$request_length';
EOF

  local http_root="return 301 https://\$host\$request_uri;"
  nft list table inet cdnlock >/dev/null 2>&1 && http_root="return 444;"

  cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;
    server_name _;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { $http_root }
}

server {
    listen 443 ssl default_server$h2_listen;
$h2_line
    server_name $CDN_DOMAIN;
    ssl_certificate     $crt/fullchain.pem;
    ssl_certificate_key $crt/privkey.pem;

    client_header_buffer_size 16k;
    large_client_header_buffers 8 64k;
    keepalive_timeout 1h;
    keepalive_requests 100000;

    # CDN ходит к источнику по HTTPS — сюда же прилетает ACME при продлении через webroot
    location /.well-known/acme-challenge/ { root /var/www/html; }

    location $XHTTP_PATH {
        if (\$from_yc_cdn = 0) { return 404; }
        proxy_pass http://127.0.0.1:$XRAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        client_max_body_size 0;
        add_header Cache-Control "no-store, no-transform" always;
        access_log /var/log/nginx/xhttp.log xhttp;
    }

$site_loc
}
EOF
  rm -f /etc/nginx/sites-enabled/panel /etc/nginx/sites-available/panel
  ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx || return 1
  local code; code=$(local_https /)
  [[ "$code" == 200 ]] && ok "nginx отдаёт https://$CDN_DOMAIN/ (200)" || warn "https://$CDN_DOMAIN/ на сервере ответил $code"
  verify_cdn_https || return 1
}

step_xui() {
  local u p path bk="" kind=""
  for f in /root/3xui-backup-*.tar.gz /root/3xui-backup.tar.gz /root/xui-pg.dump /root/x-ui.db; do
    [[ -f "$f" ]] && { bk=$f; break; }
  done
  say "Бэкап 3x-ui со старого сервера (если переезд):"
  say "  • Postgres: архив от ${c_b}bash $0 backup${c_0} или файл ${c_b}xui-pg.dump${c_0}"
  say "  • SQLite:   архив с etc/x-ui или файл x-ui.db"
  say "Залей на этот сервер: scp бэкап root@${SERVER_IP}:/root/"
  ask bk "Путь к бэкапу (- или пусто — чистая установка)" "$bk"
  [[ "$bk" == - ]] && bk=""
  [[ -z "$bk" || -f "$bk" ]] || { err "Нет файла $bk"; return 1; }
  if [[ -n "$bk" ]]; then
    kind=$(xui_backup_kind "$bk")
    [[ -n "$kind" ]] || { err "Не понял тип бэкапа ($bk). Нужен xui-pg.dump / *.db / архив от «$0 backup»"; return 1; }
    say "Тип бэкапа: ${c_b}$kind${c_0}"
  fi

  if [[ -f $PANEL_TXT ]]; then
    u=$(awk '/^Login:/{print $2}' $PANEL_TXT); p=$(awk '/^Pass:/{print $2}' $PANEL_TXT); path=$(panel_path)
    [[ "$u" == "(из" ]] && u="" p=""
  fi
  u=${u:-admin$(openssl rand -hex 3)}; p=${p:-$(openssl rand -hex 12)}; path=${path:-$(openssl rand -hex 8)}

  if [[ ! -x /usr/local/x-ui/x-ui ]]; then
    XUI_NONINTERACTIVE=1 XUI_SSL_MODE=none XUI_PANEL_PORT=$PANEL_PORT XUI_USERNAME="$u" XUI_PASSWORD="$p" XUI_WEB_BASE_PATH="$path" \
      bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) </dev/null || return 1
  fi

  if [[ -n "$bk" ]]; then
    systemctl stop x-ui 2>/dev/null || true
    XUI_RESTORE_COUNTS=""
    if [[ "$kind" == postgres ]]; then
      xui_restore_postgres "$bk" || return 1
    else
      xui_restore_sqlite "$bk" || return 1
    fi
    systemctl start x-ui; sleep 5
    /usr/local/x-ui/x-ui setting -listenIP 127.0.0.1 -port $PANEL_PORT >/dev/null 2>&1
    /usr/local/x-ui/x-ui cert -reset >/dev/null 2>&1
    systemctl restart x-ui; sleep 5
    XUI_RESTORED=1; save XUI_RESTORED
    ok "3x-ui восстановлена из $bk (${kind}; inbounds/users/clients = ${XUI_RESTORE_COUNTS:-?}; логин/пароль — из бэкапа)"
  else
    systemctl restart x-ui; sleep 5
    local out
    out=$(/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1 -port $PANEL_PORT -username "$u" -password "$p" -webBasePath "$path" -resetTwoFactor 2>&1)
    /usr/local/x-ui/x-ui cert -reset >/dev/null 2>&1
    systemctl restart x-ui; sleep 5
    if echo "$out" | grep -q "Username and password updated successfully"; then ok "Логин и пароль панели применены"
    else warn "Логин/пароль могли не примениться:"; echo "$out"; say "Если войти не получится — запусти скрипт и повтори этот шаг."
    fi
    XUI_RESTORED=0; save XUI_RESTORED
  fi
  chmod 600 $PANEL_TXT 2>/dev/null || true
  systemctl is-active --quiet x-ui && ok "x-ui запущен" || { err "x-ui не запущен: journalctl -u x-ui -n 50"; return 1; }
  path=$(xui_base_path)
  if [[ "${XUI_RESTORED:-0}" == 1 ]]; then
    printf "URL:   http://localhost:8443/%s/\nLogin: (из бэкапа)\nPass:  (из бэкапа)\n" "$path" > $PANEL_TXT
  else
    printf "URL:   http://localhost:8443/%s/\nLogin: %s\nPass:  %s\n" "$path" "$u" "$p" > $PANEL_TXT
  fi
  chmod 600 $PANEL_TXT
  local code; code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:$PANEL_PORT/${path}/")
  [[ "$code" == 200 || "$code" == 302 || "$code" == 401 ]] && ok "Панель отвечает на 127.0.0.1:$PANEL_PORT/${path}/ (код $code)" \
    || warn "Панель на 127.0.0.1:$PANEL_PORT/${path}/ ответила $code — смотри: /usr/local/x-ui/x-ui setting -show"
  say "\n${c_b}Панель 3x-ui${c_0} (слушает только 127.0.0.1, снаружи закрыта):"; cat $PANEL_TXT
  panel_tunnel_hint
}

step_panel_gui() {
  if [[ "${XUI_RESTORED:-0}" == 1 ]]; then
    say "Подключение и клиенты взяты из бэкапа. В панели проверь только:"
    say "  «Входящие» → cdn-xhttp: порт ${c_b}$XRAY_PORT${c_0}, путь ${c_b}$XHTTP_PATH${c_0};  «Хосты»: адрес и SNI = ${c_b}$CDN_DOMAIN${c_0}."
  else
    say "Открой панель через SSH-туннель (команда выше), логин и пароль — в $PANEL_TXT"
    todo "1. «Дашборд» → обнови Xray до последней версии."
    todo "2. «Входящие» → «Создать подключение» → внизу «Дополнительные настройки» → раздел «Всё»."
    say  "   Удали всё в редакторе, вставь JSON ниже и сохрани:"
    cat <<EOF
${c_b}
{
  "listen": "127.0.0.1",
  "port": $XRAY_PORT,
  "protocol": "vless",
  "tag": "cdn-xhttp",
  "remark": "cdn-xhttp",
  "settings": { "clients": [], "decryption": "none" },
  "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] },
  "streamSettings": {
    "network": "xhttp",
    "security": "none",
    "xhttpSettings": {
      "path": "$XHTTP_PATH",
      "mode": "packet-up",
      "uplinkHTTPMethod": "GET",
      "uplinkDataPlacement": "header",
      "uplinkDataKey": "x-edge-data",
      "scMaxEachPostBytes": "8192",
      "serverMaxHeaderBytes": 65536
    }
  }
}
${c_0}
EOF
    todo "3. «Клиенты» → «Добавить клиента»: Email любой (например phone), «Привязанные входящие» → cdn-xhttp → сохранить."
    todo "4. «Хосты» → «Добавить хост»:"
    say  "   Основное:     Входящие = cdn-xhttp,  Адрес = ${c_b}${CDN_DOMAIN}${c_0} (БЕЗ :443, нажми Enter чтобы появился тег),  Порт = 443"
    say  "   Безопасность: tls,  SNI = ${c_b}${CDN_DOMAIN}${c_0},  Fingerprint = chrome"
    say  "   Дополнительно: всё пустое → сохранить."
  fi
  pause
  for _ in $(seq 1 10); do ss -tln | grep -q "127.0.0.1:$XRAY_PORT " && { ok "Xray слушает 127.0.0.1:$XRAY_PORT"; break; }; sleep 2; done
  local code; code=$(local_https "$XHTTP_PATH/test")
  [[ "$code" == 400 ]] && ok "Туннель за nginx отвечает (код 400 — это нормально)" \
    || { warn "https://$CDN_DOMAIN$XHTTP_PATH/test на сервере ответил $code (ожидался 400). Проверь порт и путь подключения в панели."; yes_no "Продолжить?" n || return 1; }
}

step_selftest() {
  local link uuid bin
  say "Проверим туннель целиком: запустим на сервере тестовый клиент, который пойдёт через CDN."
  todo "В панели: «Клиенты» → иконка QR или «i» у клиента → скопируй ссылку vless://"
  read -r -p "Вставь ссылку и нажми Enter: " link </dev/tty
  uuid=$(echo "$link" | sed -E 's#^vless://([^@]+)@.*#\1#')
  [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || { err "Не нашёл UUID в ссылке"; return 1; }
  [[ "$link" == *"@$CDN_DOMAIN:443"* ]] || warn "В ссылке адрес не $CDN_DOMAIN:443 — проверь «Хосты» в панели."
  [[ "$link" == *"sni=$CDN_DOMAIN"* ]] || warn "В ссылке SNI не $CDN_DOMAIN — проверь «Хосты» в панели."
  [[ "$link" == *uplinkHTTPMethod* ]] || warn "В ссылке нет uplinkHTTPMethod — в клиенте добавь его в поле extra (см. ниже)."
  bin=$(ls /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -n1)
  [[ -x "$bin" ]] || { err "Не найден бинарник Xray в /usr/local/x-ui/bin"; return 1; }
  cat > /tmp/cdn-test-client.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{ "listen": "127.0.0.1", "port": 10808, "protocol": "socks" }],
  "outbounds": [{
    "protocol": "vless",
    "settings": { "vnext": [{ "address": "$CDN_DOMAIN", "port": 443, "users": [{ "id": "$uuid", "encryption": "none" }] }] },
    "streamSettings": {
      "network": "xhttp",
      "security": "tls",
      "tlsSettings": { "serverName": "$CDN_DOMAIN", "fingerprint": "chrome" },
      "xhttpSettings": {
        "path": "$XHTTP_PATH",
        "mode": "packet-up",
        "extra": { "uplinkHTTPMethod": "GET", "uplinkDataPlacement": "header", "uplinkDataKey": "x-edge-data", "scMaxEachPostBytes": "8192" }
      }
    }
  }]
}
EOF
  "$bin" run -c /tmp/cdn-test-client.json >/tmp/cdn-test-client.log 2>&1 &
  local pid=$!; sleep 2
  local ip; ip=$(curl -s -m 20 --socks5-hostname 127.0.0.1:10808 https://ifconfig.me)
  kill $pid 2>/dev/null; rm -f /tmp/cdn-test-client.json
  if [[ "$ip" == "$SERVER_IP" ]]; then ok "Туннель через CDN работает: выход в интернет с IP $ip"
  else err "Тест не прошёл (получено: '${ip}')"; tail -n 15 /tmp/cdn-test-client.log; tail -n 10 /var/log/nginx/xhttp.log; return 1
  fi
}

ensure_geo() {
  [[ -f /etc/nginx/conf.d/cdn-geo.conf ]] || echo 'geo $from_yc_cdn { default 1; }' > /etc/nginx/conf.d/cdn-geo.conf
}

install_lock() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables curl python3 >/dev/null || return 1
  mkdir -p /etc/cdn-lock
  rm -f /etc/cdn-lock/open-443
  cat > /usr/local/sbin/cdn-lock.sh <<'EOF'
#!/usr/bin/env bash
# 443/tcp — только с подсетей Yandex CDN (официальный список), 2096 (подписки 3x-ui) — закрыт,
# 2053 (панель) — только с IP из /etc/cdn-lock/panel-allow.txt.
# Список подсетей также пишется в nginx (geo $from_yc_cdn) — туннель отвечает только Yandex CDN.
# SSH и 80 (продление Let's Encrypt через CDN) не трогаются. Отключить: nft delete table inet cdnlock
CACHE=/etc/cdn-lock/prefixes.txt
GEO=/etc/nginx/conf.d/cdn-geo.conf
ALLOW=/etc/cdn-lock/panel-allow.txt
PANEL_ACCEPT=""
[ -s "$ALLOW" ] && PANEL_ACCEPT="tcp dport 2053 ip saddr { $(paste -sd, "$ALLOW") } accept"
tmp=$(mktemp)
if curl -fsS --max-time 20 https://tech.cdn.yandex.net/prefixes/yc.json \
   | python3 -c 'import json,sys,ipaddress;[print(p) for p in json.load(sys.stdin)["prefixes"] if ipaddress.ip_network(p,strict=False).version==4]' > "$tmp" \
   && [ "$(wc -l < "$tmp")" -gt 10 ]; then
  mv "$tmp" "$CACHE"
else
  rm -f "$tmp"
fi
[ -s "$CACHE" ] || { echo "cdn-lock: нет списка подсетей Yandex CDN" >&2; exit 1; }
geo_new=$(mktemp)
{ echo 'geo $from_yc_cdn {'; echo '    default 0;'; sed 's/.*/    & 1;/' "$CACHE"; echo '}'; } > "$geo_new"
if cmp -s "$geo_new" "$GEO"; then rm -f "$geo_new"
else mv "$geo_new" "$GEO"; chmod 644 "$GEO"; nginx -t -q && systemctl reload nginx
fi
nft -f - <<NFT
table inet cdnlock
delete table inet cdnlock
table inet cdnlock {
  set yc { type ipv4_addr; flags interval; auto-merge; elements = { $(paste -sd, "$CACHE") } }
  chain input {
    type filter hook input priority -10; policy accept;
    iif lo accept
    ct state established,related accept
    tcp dport 443 ip saddr @yc accept
    $PANEL_ACCEPT
    tcp dport { 443, 2053, 2096 } drop
    udp dport 443 drop
  }
}
NFT
EOF
  chmod 755 /usr/local/sbin/cdn-lock.sh
  cat > /etc/cron.d/cdn-lock <<'EOF'
@reboot root sleep 20; /usr/local/sbin/cdn-lock.sh
17 4 * * * root /usr/local/sbin/cdn-lock.sh
EOF
  sed -i 's#location / { return 301 https://\$host\$request_uri; }#location / { return 444; }#' /etc/nginx/sites-available/default
  nginx -t -q && systemctl reload nginx

  /usr/local/sbin/cdn-lock.sh || return 1
  ok "Порт 443 открыт только для Yandex CDN ($(wc -l < /etc/cdn-lock/prefixes.txt) подсетей), список обновляется ежедневно"
}

step_lock() {
  say "Закроем сервер от всех, кроме узлов Yandex CDN:"
  say "  • 443 — только с подсетей Yandex CDN, туннель отвечает только им;"
  say "  • 80 — только для продления сертификата, остальное соединение сбрасывается;"
  say "  • панель (2053) и подписки (2096) закрыты, SSH не трогается."
  yes_no "Включить?" y || { warn "Пропущено. Включить позже: bash $0 lock"; return 0; }
  install_lock || return 1
  sleep 3
  local code; code=$(curl -s -o /dev/null --max-time 20 -w '%{http_code}' "https://$CDN_DOMAIN/")
  if [[ "$code" == 200 ]]; then ok "https://$CDN_DOMAIN/ по-прежнему отвечает 200"
  else
    err "https://$CDN_DOMAIN/ ответил $code"
    yes_no "Откатить блокировку?" y && { step_unlock; return 1; }
  fi
  say "Снять ограничение в любой момент: ${c_b}bash $0 unlock${c_0}"
}

step_unlock() {
  nft delete table inet cdnlock 2>/dev/null
  rm -f /etc/cron.d/cdn-lock /etc/cdn-lock/open-443
  echo 'geo $from_yc_cdn { default 1; }' > /etc/nginx/conf.d/cdn-geo.conf
  sed -i 's#location / { return 444; }#location / { return 301 https://$host$request_uri; }#' /etc/nginx/sites-available/default 2>/dev/null
  nginx -t -q && systemctl reload nginx
  eval "STEP_11=0"; save STEP_11
  ok "Ограничение снято: порты 80/443 открыты для всех. Включить снова: bash $0 lock"
}

step_panel_proxy() {
  local ip path crt="/etc/letsencrypt/live/${CDN_DOMAIN}" conf="/etc/letsencrypt/renewal/${CDN_DOMAIN}.conf"
  [[ -f "$crt/fullchain.pem" ]] || { err "Нет сертификата $crt — сначала выполни полную настройку"; return 1; }
  say "Панель будет слушать порт $PANEL_PORT по HTTPS, доступ — только с IP сервера, где стоит reverse proxy."
  while true; do
    ask ip "Публичный IPv4 сервера с Nginx Proxy Manager" "$(head -n1 /etc/cdn-lock/panel-allow.txt 2>/dev/null)"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
    err "Некорректный IPv4: '$ip'"
  done
  mkdir -p /etc/cdn-lock; echo "$ip" > /etc/cdn-lock/panel-allow.txt

  /usr/local/x-ui/x-ui setting -listenIP 0.0.0.0 -webCert "$crt/fullchain.pem" -webCertKey "$crt/privkey.pem" >/dev/null || return 1
  if [[ -f "$conf" ]]; then
    sed -i '/^renew_hook/d' "$conf"
    echo 'renew_hook = systemctl reload nginx; systemctl restart x-ui' >> "$conf"
  fi
  systemctl restart x-ui
  install_lock || return 1

  path=$(panel_path)
  ok "Порт $PANEL_PORT открыт только для $ip"
  say "\nВ Nginx Proxy Manager → Hosts → Proxy Hosts → Add Proxy Host:"
  say "  Details:  Domain Names = ${c_b}<домен панели, например 3x-ui.iscreation.space>${c_0}"
  say "            Scheme = ${c_b}https${c_0},  Forward Hostname / IP = ${c_b}${SERVER_IP}${c_0},  Forward Port = ${c_b}${PANEL_PORT}${c_0}"
  say "            Websockets Support = вкл,  Block Common Exploits = вкл"
  say "  SSL:      SSL Certificate = Request a new SSL Certificate,  Force SSL = вкл,  HTTP/2 Support = вкл"
  say "  DNS домена панели: A-запись → IP сервера с Nginx Proxy Manager ($ip)"
  say "\nПанель откроется по адресу: https://<домен панели>/${path:-<путь_панели>}/"
}

panel_tunnel_hint() {
  local path; path=$(panel_path)
  say "Панель (через SSH-туннель) — на своём компьютере выполни:"
  say "  ${c_b}ssh -L 8443:127.0.0.1:$PANEL_PORT root@$SERVER_IP${c_0}"
  say "  и, не закрывая его, открой в браузере ${c_b}http://localhost:8443/${path:-<путь_панели>}/${c_0}"
}

step_finish() {
  say "${c_g}Готово.${c_0}\n"
  todo "Подключи телефон: Happ / v2RayTun / v2rayNG / v2rayN (последней версии) → импорт ссылки из панели."
  say  "Если в клиенте нет uplinkHTTPMethod, вставь в поле extra:"
  say  '  {"uplinkHTTPMethod":"GET","uplinkDataPlacement":"header","uplinkDataKey":"x-edge-data","scMaxEachPostBytes":"8192"}'
  say  "\nПроверка с телефона (мобильный интернет, без другого VPN):"
  say  "  1) https://$CDN_DOMAIN должен открыть сайт;"
  say  "  2) при подключении в  tail -f /var/log/nginx/xhttp.log  появляются строки GET $XHTTP_PATH/... status=200."
  echo; panel_tunnel_hint; say "Доступы: $PANEL_TXT"
  say  "Логи:   journalctl -u x-ui -f   |   tail -f /var/log/nginx/error.log"
  [[ "$SITE_MODE" == 2 ]] && say "Обновить сайт: запусти этот скрипт и повтори шаг 6 (или: cd /opt/site && git pull && docker compose up -d --build)"
  say  "\nПереезд: на старом ${c_b}bash $0 backup${c_0} → scp архива на новый → там этот скрипт (указать бэкап) → в CDN сменить источник на новый IP."
  say  "Бэкап сам определит Postgres или SQLite. DNS/CNAME/сертификат Яндекса трогать не нужно."
}

# ---------------------------------------------------------------- main

[[ $EUID -eq 0 ]] || { err "Запусти от root"; exit 1; }
command -v apt-get >/dev/null || { err "Нужна Ubuntu/Debian"; exit 1; }
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
command -v dig >/dev/null || { apt-get update -qq && apt-get install -y -qq dnsutils >/dev/null; }

[[ -f "$STATE" ]] && . "$STATE"

if [[ "${1:-}" == backup ]]; then
  hdr B "Бэкап 3x-ui (Postgres / SQLite)"
  step_backup
  exit
fi

if [[ "${1:-}" == panel-proxy ]]; then
  ask_domain CDN_DOMAIN "CDN-домен (на него выпущен сертификат на этом сервере)" "${CDN_DOMAIN:-}"; save CDN_DOMAIN
  [[ -n "${SERVER_IP:-}" ]] || { SERVER_IP=$(curl -4 -fsS --max-time 10 https://ifconfig.me); save SERVER_IP; }
  hdr 13 "Панель через внешний reverse proxy"
  step_panel_proxy
  exit
fi

if [[ "${1:-}" == unlock ]]; then
  hdr 11 "Снятие ограничения доступа"
  step_unlock
  exit
fi

if [[ "${1:-}" == lock ]]; then
  ask_domain CDN_DOMAIN "CDN-домен" "${CDN_DOMAIN:-}"; save CDN_DOMAIN
  [[ -n "${SERVER_IP:-}" ]] || { SERVER_IP=$(curl -4 -fsS --max-time 10 https://ifconfig.me); save SERVER_IP; }
  hdr 11 "Доступ только для Yandex CDN"
  step_lock && done_step 11
  exit
fi

if [[ -f "$STATE" ]] && yes_no "Найдена предыдущая настройка ($STATE). Начать заново с нуля?" n; then
  rm -f "$STATE"; unset $(compgen -v | grep "^STEP_")
fi

say "${c_b}Настройка VLESS + XHTTP через Yandex Cloud CDN${c_0}"
say "Скрипт поставит nginx, сертификат, 3x-ui (или восстановит её из бэкапа) и подскажет, что сделать в Yandex Cloud."

run_step 1  "Параметры"                        step_params
run_step 2  "Пакеты и проверка IP"             step_packages
run_step 3  "Сертификат в Yandex Cloud"        step_yc_cert
run_step 4  "Yandex Cloud CDN и CNAME"         step_cdn
run_step 5  "Сертификат на сервере"            step_cert
run_step 6  "Сайт на главной"                  step_site
run_step 7  "Настройка nginx"                  step_nginx
run_step 8  "Установка 3x-ui"                  step_xui
run_step 9  "Настройка панели"                 step_panel_gui
run_step 10 "Проверка туннеля"                 step_selftest
run_step 11 "Доступ только для Yandex CDN"     step_lock
hdr 12 "Итог"; step_finish
