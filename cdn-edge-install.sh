#!/usr/bin/env bash
# Ставит на этот сервер локальный API смены IP в 3x-ui и открывает его в nginx.
# Запуск на сервере от root, из каталога с cdn-edge-api.py и cdn-vpn-rotate.py:
#   bash cdn-edge-install.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "запусти от root" >&2; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$SRC/cdn-edge-api.py" && -f "$SRC/cdn-vpn-rotate.py" ]] || {
  echo "рядом нужны cdn-edge-api.py и cdn-vpn-rotate.py" >&2
  exit 1
}

install -d -m 755 /usr/local/lib/cdn-edge /etc/cdn-edge
install -m 644 "$SRC/cdn-edge-api.py" "$SRC/cdn-vpn-rotate.py" /usr/local/lib/cdn-edge/

if [[ ! -s /etc/cdn-edge/token ]]; then
  openssl rand -hex 32 > /etc/cdn-edge/token
fi
chmod 600 /etc/cdn-edge/token
TOKEN="$(cat /etc/cdn-edge/token)"

cat > /etc/systemd/system/cdn-edge-api.service <<'EOF'
[Unit]
Description=CDN edge address API for 3x-ui
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/lib/cdn-edge/cdn-edge-api.py
Restart=on-failure
RestartSec=2
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cdn-edge-api.service
systemctl restart cdn-edge-api.service

SITE=/etc/nginx/sites-enabled/default
if [[ -L "$SITE" ]]; then
  SITE="$(readlink -f "$SITE")"
fi
[[ -f "$SITE" ]] || { echo "нет $SITE" >&2; exit 1; }
cp -a "$SITE" "$SITE.bak-edge"

python3 - "$SITE" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
block = """
    # BEGIN cdn-edge-api
    location = /_edge/v1 {
        if ($from_yc_cdn = 0) { return 404; }
        proxy_pass http://127.0.0.1:8791;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Edge-Token $http_x_edge_token;
        proxy_set_header Authorization $http_authorization;
        client_max_body_size 1k;
        add_header Cache-Control "no-store" always;
        access_log off;
    }
    # END cdn-edge-api
"""
start = text.find("# BEGIN cdn-edge-api")
end = text.find("# END cdn-edge-api")
if start != -1 and end != -1:
    end = text.find("\n", end)
    text = text[:start] + block.strip("\n") + text[end:]
else:
    needle = "    location / {"
    at = text.find(needle)
    if at == -1:
        sys.exit("в nginx нет location /")
    text = text[:at] + block + "\n" + text[at:]
open(path, "w", encoding="utf-8").write(text)
PY

if ! nginx -t; then
  mv "$SITE.bak-edge" "$SITE"
  echo "nginx -t не прошёл, конфиг возвращён" >&2
  exit 1
fi
systemctl reload nginx

DOMAIN="cdn.iscreation.ru"
if [[ -f /root/.cdn-vpn.env ]]; then
  # shellcheck disable=SC1091
  . /root/.cdn-vpn.env
  DOMAIN="${CDN_DOMAIN:-$DOMAIN}"
fi

echo
echo "Слушатель запущен. На компьютере со сканером:"
echo "export CDN_EDGE_URL=https://${DOMAIN}/_edge/v1"
echo "export CDN_EDGE_TOKEN=${TOKEN}"
echo
echo "Проверка API на самом сервере (минуя nginx):"
echo "curl -fsS -H \"X-Edge-Token: ${TOKEN}\" http://127.0.0.1:8791/_edge/v1"
echo "С компьютера запрос пойдёт через CDN: 443 с других сетей закрыт."
