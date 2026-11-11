#!/usr/bin/env bash
# VLESS + XHTTP через Yandex Cloud CDN: nginx + certbot + 3x-ui (+ сайт на главной).
# Запуск: bash cdn-vpn-setup.sh   (под root, Ubuntu/Debian)
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
  if [[ -n "$__d" ]]; then read -r -p "$__q [$__d]: " __a </dev/tty; else read -r -p "$__q: " __a </dev/tty; fi
  printf -v "$__v" '%s' "${__a:-$__d}"
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

resolve() { dig +short "$1" A @1.1.1.1 2>/dev/null | tail -n1; }
resolve_chain() { dig +short "$1" @1.1.1.1 2>/dev/null | tr '\n' ' '; }

# ---------------------------------------------------------------- шаги

step_params() {
  ask BASE_DOMAIN  "Основной домен (на нём будет сайт и источник для CDN)" "${BASE_DOMAIN:-}"
  [[ -z "$BASE_DOMAIN" ]] && { err "Домен обязателен"; return 1; }
  ask PANEL_DOMAIN "Поддомен для панели 3x-ui" "${PANEL_DOMAIN:-panel.$BASE_DOMAIN}"
  ask CDN_DOMAIN   "Поддомен для CDN (к нему подключаются клиенты)" "${CDN_DOMAIN:-cdn.$BASE_DOMAIN}"
  ask XHTTP_PATH   "Путь туннеля" "${XHTTP_PATH:-/media/hls/live}"
  [[ "$XHTTP_PATH" != /* ]] && XHTTP_PATH="/$XHTTP_PATH"

  say "\nЧто показывать на главной странице $BASE_DOMAIN?"
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

  for v in BASE_DOMAIN PANEL_DOMAIN CDN_DOMAIN XHTTP_PATH SITE_MODE SERVER_IP; do save "$v"; done
  [[ "$SITE_MODE" == 2 ]] && { save SITE_REPO; save SITE_PORT; }
  ok "Параметры сохранены в $STATE"
}

step_packages() {
  apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot dnsutils curl python3 openssl git || return 1
  mkdir -p /var/www/html
  [[ -f /var/www/html/index.html ]] || cat > /var/www/html/index.html <<EOF
<!doctype html><html><head><meta charset="utf-8"><title>$BASE_DOMAIN</title></head><body><h1>$BASE_DOMAIN</h1></body></html>
EOF
  if [[ ! -f /etc/letsencrypt/live/$BASE_DOMAIN/fullchain.pem ]]; then
    cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 80 default_server;
    server_name _;
    root /var/www/html;
}
EOF
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-enabled/panel
  fi
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

step_dns() {
  say "У регистратора домена создай A-записи (если их ещё нет):"
  say "  ${c_b}${BASE_DOMAIN}${c_0}   →  A  →  ${SERVER_IP}"
  say "  ${c_b}${PANEL_DOMAIN}${c_0}  →  A  →  ${SERVER_IP}"
  say "Для ${CDN_DOMAIN} пока ничего не создавай. Если есть A-запись для него или wildcard (*), удали их."
  pause
  while true; do
    local a b; a=$(resolve "$BASE_DOMAIN"); b=$(resolve "$PANEL_DOMAIN")
    say "  $BASE_DOMAIN → ${a:-нет}    $PANEL_DOMAIN → ${b:-нет}"
    if [[ "$a" == "$SERVER_IP" && "$b" == "$SERVER_IP" ]]; then ok "DNS указывает на сервер"; return 0; fi
    warn "DNS ещё не обновился (обычно 5–30 минут)."
    yes_no "Проверить снова через 60 секунд?" y || { yes_no "Продолжить без проверки?" n && return 0 || return 1; }
    sleep 60
  done
}

step_yc_cert() {
  local sub="${CDN_DOMAIN%.$BASE_DOMAIN}"
  say "Выпустим сертификат для ${CDN_DOMAIN} в Yandex Cloud. Пока он выпускается (20–30 минут), скрипт продолжит настройку сервера."
  say "Если CDN для ${CDN_DOMAIN} у тебя уже настроен и работает (переезд на новый сервер) — просто нажми Enter."
  todo "1. Зарегистрируйся на console.yandex.cloud и пополни баланс (~300 ₽)."
  todo "2. Certificate Manager → «Добавить сертификат» → «Сертификат от Let's Encrypt»."
  say  "      Имя: ${c_b}cdn-cert${c_0}    Домен: ${c_b}${CDN_DOMAIN}${c_0}    Тип проверки: ${c_b}DNS${c_0}  → «Создать»"
  todo "3. Открой сертификат → «Проверка прав на домены» → TXT-запись."
  say  "      У регистратора создай TXT-запись:"
  say  "      Имя/Subdomain: ${c_b}_acme-challenge.${sub}${c_0}  (если поле требует полное имя: _acme-challenge.${CDN_DOMAIN})"
  say  "      Значение/Text: строка из консоли Яндекса, без кавычек"
  say  "   Ждать статуса «Issued» не нужно — вернёмся к нему позже."
  pause
}

step_cert() {
  certbot certonly --webroot -w /var/www/html --cert-name "$BASE_DOMAIN" --expand \
    -d "$BASE_DOMAIN" -d "$PANEL_DOMAIN" --agree-tos --register-unsafely-without-email -n \
    --deploy-hook "systemctl reload nginx" || { err "certbot не смог выпустить сертификат. Проверь DNS-записи из шага 3."; return 1; }
  ok "Сертификат: /etc/letsencrypt/live/$BASE_DOMAIN/"
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
  local crt="/etc/letsencrypt/live/$BASE_DOMAIN"
  local h2_listen="" h2_line="    http2 on;"
  # директива "http2 on" появилась в nginx 1.25.1
  if ! printf '%s\n' "1.25.1" "$(nginx -v 2>&1 | sed -E 's#.*/([0-9.]+).*#\1#')" | sort -V -C; then
    h2_listen=" http2"; h2_line=""
  fi

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
    server_name $BASE_DOMAIN;
    ssl_certificate     $crt/fullchain.pem;
    ssl_certificate_key $crt/privkey.pem;

    client_header_buffer_size 16k;
    large_client_header_buffers 8 64k;
    keepalive_timeout 1h;
    keepalive_requests 100000;

    location $XHTTP_PATH {
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

  cat > /etc/nginx/sites-available/panel <<EOF
server {
    listen 443 ssl$h2_listen;
$h2_line
    server_name $PANEL_DOMAIN;
    ssl_certificate     $crt/fullchain.pem;
    ssl_certificate_key $crt/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 600s;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/panel /etc/nginx/sites-enabled/panel
  nginx -t && systemctl reload nginx || return 1
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' "https://$BASE_DOMAIN/")
  [[ "$code" == 200 ]] && ok "https://$BASE_DOMAIN/ отвечает 200" || warn "https://$BASE_DOMAIN/ ответил $code"
}

step_xui() {
  local u p path
  if [[ -f $PANEL_TXT ]]; then
    u=$(awk '/^Login:/{print $2}' $PANEL_TXT); p=$(awk '/^Pass:/{print $2}' $PANEL_TXT)
    path=$(awk '/^URL:/{print $2}' $PANEL_TXT | sed -E 's#https://[^/]+/([^/]+)/?#\1#')
  fi
  u=${u:-admin$(openssl rand -hex 3)}; p=${p:-$(openssl rand -hex 12)}; path=${path:-$(openssl rand -hex 8)}

  if [[ ! -x /usr/local/x-ui/x-ui ]]; then
    XUI_NONINTERACTIVE=1 XUI_SSL_MODE=none XUI_PANEL_PORT=$PANEL_PORT XUI_USERNAME="$u" XUI_PASSWORD="$p" XUI_WEB_BASE_PATH="$path" \
      bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) </dev/null || return 1
  fi
  # пользователь панели создаётся при первом запуске x-ui, поэтому логин задаём после старта
  systemctl restart x-ui; sleep 5
  local out
  out=$(/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1 -port $PANEL_PORT -username "$u" -password "$p" -webBasePath "$path" -resetTwoFactor 2>&1)
  /usr/local/x-ui/x-ui cert -reset >/dev/null 2>&1
  systemctl restart x-ui; sleep 5

  printf "URL:   https://%s/%s/\nLogin: %s\nPass:  %s\n" "$PANEL_DOMAIN" "$path" "$u" "$p" > $PANEL_TXT
  chmod 600 $PANEL_TXT

  if echo "$out" | grep -q "Username and password updated successfully"; then ok "Логин и пароль панели применены"
  else warn "Логин/пароль могли не примениться:"; echo "$out"; say "Если войти не получится — запусти скрипт и повтори шаг 8."
  fi
  systemctl is-active --quiet x-ui && ok "x-ui запущен" || { err "x-ui не запущен: journalctl -u x-ui -n 50"; return 1; }
  say "\n${c_b}Панель 3x-ui:${c_0}"; cat $PANEL_TXT
  say "(сохранено в $PANEL_TXT)"
}

step_panel_gui() {
  say "Открой панель: $(awk '/^URL:/{print $2}' $PANEL_TXT)  (логин и пароль — выше или в $PANEL_TXT)"
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
  pause
  for _ in $(seq 1 10); do ss -tln | grep -q "127.0.0.1:$XRAY_PORT " && { ok "Xray слушает 127.0.0.1:$XRAY_PORT"; break; }; sleep 2; done
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' "https://$BASE_DOMAIN$XHTTP_PATH/test")
  [[ "$code" == 400 || "$code" == 404 ]] && ok "Туннель за nginx отвечает (код $code — это нормально)" \
    || { warn "https://$BASE_DOMAIN$XHTTP_PATH/test ответил $code (ожидался 400). Проверь подключение в панели."; yes_no "Продолжить?" n || return 1; }
}

step_cdn() {
  say "Если CDN для ${CDN_DOMAIN} уже настроен (переезд), проверь только одно: источник в ресурсе — ${c_b}${BASE_DOMAIN}${c_0}, заголовок Host — ${c_b}${BASE_DOMAIN}${c_0}. Затем нажми Enter."
  todo "1. Certificate Manager: дождись статуса «Issued» у сертификата cdn-cert."
  todo "2. Cloud CDN → «Создать ресурс»:"
  say  "   Запрос контента: Из одного источника;  Тип источника: Сервер;  Адрес: ${c_b}${BASE_DOMAIN}${c_0}"
  say  "   Протокол для источников: ${c_b}HTTPS${c_0}"
  say  "   Доменное имя: ${c_b}${CDN_DOMAIN}${c_0}"
  say  "   Переадресация клиентов: Не использовать"
  say  "   Тип сертификата: ${c_b}Сертификат из Certificate Manager → cdn-cert${c_0}   (НЕ «Не использовать»!)"
  say  "   Заголовок Host: Своё значение → ${c_b}${BASE_DOMAIN}${c_0}"
  say  "   Кеширование в CDN: выкл;  Кеширование в браузере: выкл"
  say  "   Разрешённые методы: GET, HEAD, OPTIONS"
  say  "   Экранирование источников: выкл;  Выгрузка логов: выкл"
  todo "3. Открой ресурс → внизу «Настройки DNS» → у регистратора создай CNAME:"
  say  "   Имя: ${c_b}${CDN_DOMAIN%.$BASE_DOMAIN}${c_0}   Значение: технический домен из консоли (xxxx.gslb.yccdn.ru)"
  pause
  while true; do
    local chain subj code
    chain=$(resolve_chain "$CDN_DOMAIN")
    subj=$(curl -vkI --max-time 15 "https://$CDN_DOMAIN/" 2>&1 | sed -n 's/.*subject: //p' | head -n1)
    code=$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' "https://$CDN_DOMAIN/")
    say "  DNS: ${chain:-нет}"
    say "  Сертификат: ${subj:-нет}"
    say "  Ответ: $code"
    if [[ "$chain" == *yccdn* && "$subj" == *"$CDN_DOMAIN"* && "$code" == 200 ]]; then ok "CDN работает"; return 0; fi
    [[ "$chain" != *yccdn* ]] && warn "CNAME ещё не указывает на Yandex CDN."
    [[ "$subj" == *yccdn.cloud.yandex.net* ]] && warn "CDN отдаёт свой сертификат: в ресурсе не выбран cdn-cert (Тип сертификата) или он ещё применяется."
    [[ "$code" == 504 ]] && warn "504: CDN не дождался ответа сервера. Если повторяется — проверь, не заблокирован ли IP."
    yes_no "Проверить снова через 2 минуты? (применение настроек CDN занимает до 30 минут)" y || { yes_no "Продолжить без проверки?" n && return 0 || return 1; }
    sleep 120
  done
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

install_lock() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables curl python3 >/dev/null || return 1
  mkdir -p /etc/cdn-lock
  cat > /usr/local/sbin/cdn-lock.sh <<'EOF'
#!/usr/bin/env bash
# 443/tcp — только с подсетей Yandex CDN (официальный список), 2096 (подписки 3x-ui) — закрыт.
# SSH и 80 (продление Let's Encrypt) не трогаются. Отключить: nft delete table inet cdnlock
CACHE=/etc/cdn-lock/prefixes.txt
tmp=$(mktemp)
if curl -fsS --max-time 20 https://tech.cdn.yandex.net/prefixes/yc.json \
   | python3 -c 'import json,sys,ipaddress;[print(p) for p in json.load(sys.stdin)["prefixes"] if ipaddress.ip_network(p,strict=False).version==4]' > "$tmp" \
   && [ "$(wc -l < "$tmp")" -gt 10 ]; then
  mv "$tmp" "$CACHE"
else
  rm -f "$tmp"
fi
[ -s "$CACHE" ] || { echo "cdn-lock: нет списка подсетей Yandex CDN" >&2; exit 1; }
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
    tcp dport { 443, 2096 } drop
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

  if grep -q 'return 301 https://\$host\$request_uri;' /etc/nginx/sites-available/default; then
    sed -i 's#location / { return 301 https://\$host\$request_uri; }#location / { return 444; }#' /etc/nginx/sites-available/default
    nginx -t && systemctl reload nginx
  fi

  /usr/local/sbin/cdn-lock.sh || return 1
  ok "Порт 443 открыт только для Yandex CDN ($(wc -l < /etc/cdn-lock/prefixes.txt) подсетей), список обновляется ежедневно"
}

step_lock() {
  say "Закроем сервер от всех, кроме узлов Yandex CDN:"
  say "  • 443 — только с подсетей Yandex CDN (сайт и туннель работают через $CDN_DOMAIN);"
  say "  • 80 — только для продления сертификата, остальное соединение сбрасывается;"
  say "  • SSH не трогается."
  say "После этого ${BASE_DOMAIN} и ${PANEL_DOMAIN} напрямую открываться не будут: сайт — через https://$CDN_DOMAIN, панель — через SSH-туннель."
  yes_no "Включить?" y || { warn "Пропущено. Включить позже: bash $0 lock"; return 0; }
  install_lock || return 1
  sleep 3
  local code; code=$(curl -s -o /dev/null --max-time 20 -w '%{http_code}' "https://$CDN_DOMAIN/")
  if [[ "$code" == 200 ]]; then ok "https://$CDN_DOMAIN/ по-прежнему отвечает 200"
  else
    err "https://$CDN_DOMAIN/ ответил $code"
    if yes_no "Откатить блокировку?" y; then
      nft delete table inet cdnlock; rm -f /etc/cron.d/cdn-lock; warn "Блокировка снята"; return 1
    fi
  fi
}

panel_tunnel_hint() {
  local path; path=$(awk '/^URL:/{print $2}' $PANEL_TXT 2>/dev/null | sed -E 's#https://[^/]+/([^/]+)/?#\1#')
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
  if nft list table inet cdnlock >/dev/null 2>&1; then echo; panel_tunnel_hint; say "Доступы: $PANEL_TXT"
  else say  "\nПанель: $(awk '/^URL:/{print $2}' $PANEL_TXT)   (доступы: $PANEL_TXT)"
  fi
  say  "Логи:   journalctl -u x-ui -f   |   tail -f /var/log/nginx/error.log"
  [[ "$SITE_MODE" == 2 ]] && say "Обновить сайт: запусти этот скрипт и повтори шаг 6 (или: cd /opt/site && git pull && docker compose up -d --build)"
  say  "\nПереезд на новый сервер: запусти этот скрипт там, затем поменяй A-записи $BASE_DOMAIN и $PANEL_DOMAIN на новый IP."
  say  "CDN, сертификат в Яндексе и CNAME трогать не нужно."
}

# ---------------------------------------------------------------- main

[[ $EUID -eq 0 ]] || { err "Запусти от root"; exit 1; }
command -v apt-get >/dev/null || { err "Нужна Ubuntu/Debian"; exit 1; }
command -v dig >/dev/null || { apt-get update -qq && apt-get install -y -qq dnsutils >/dev/null; }

[[ -f "$STATE" ]] && . "$STATE"

if [[ "${1:-}" == lock ]]; then
  [[ -n "${CDN_DOMAIN:-}" ]] || { ask CDN_DOMAIN "Домен CDN" "cdn.example.ru"; save CDN_DOMAIN; }
  [[ -n "${BASE_DOMAIN:-}" ]] || { ask BASE_DOMAIN "Основной домен" "${CDN_DOMAIN#*.}"; save BASE_DOMAIN; }
  [[ -n "${PANEL_DOMAIN:-}" ]] || { PANEL_DOMAIN="panel.$BASE_DOMAIN"; save PANEL_DOMAIN; }
  [[ -n "${SERVER_IP:-}" ]] || { SERVER_IP=$(curl -4 -fsS --max-time 10 https://ifconfig.me); save SERVER_IP; }
  hdr 12 "Доступ только для Yandex CDN"
  step_lock && done_step 12 && { echo; panel_tunnel_hint; }
  exit
fi

if [[ -f "$STATE" ]] && yes_no "Найдена предыдущая настройка ($STATE). Начать заново с нуля?" n; then
  rm -f "$STATE"; unset $(compgen -v | grep "^STEP_")
fi

say "${c_b}Настройка VLESS + XHTTP через Yandex Cloud CDN${c_0}"
say "Скрипт поставит nginx, сертификат, 3x-ui и подскажет, что сделать в панели, у регистратора и в Yandex Cloud."

run_step 1  "Параметры"                        step_params
run_step 2  "Пакеты и проверка IP"             step_packages
run_step 3  "DNS A-записи"                     step_dns
run_step 4  "Сертификат в Yandex Cloud"        step_yc_cert
run_step 5  "Сертификат Let's Encrypt"         step_cert
run_step 6  "Сайт на главной"                  step_site
run_step 7  "Настройка nginx"                  step_nginx
run_step 8  "Установка 3x-ui"                  step_xui
run_step 9  "Настройка панели"                 step_panel_gui
run_step 10 "Yandex Cloud CDN и CNAME"         step_cdn
run_step 11 "Проверка туннеля"                 step_selftest
run_step 12 "Доступ только для Yandex CDN"     step_lock
hdr 13 "Итог"; step_finish
