#!/usr/bin/env bash
# Экспорт 3x-ui со СТАРОГО сервера для переезда.
# Снимает: Postgres (если есть), SQLite (если есть), /etc/x-ui/sub-theme/, /etc/default/x-ui.
# Запуск (root):  bash cdn-vpn-export.sh
# Архив кладётся в /root/3xui-backup-YYYY-MM-DD-HHMM.tar.gz
# На новом сервере: scp архива → bash cdn-vpn-setup.sh (указать путь к бэкапу).

set -u

c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_b=$'\e[1;36m'; c_0=$'\e[0m'
say()  { echo -e "$*"; }
ok()   { echo -e "${c_g}✓ $*${c_0}"; }
warn() { echo -e "${c_y}! $*${c_0}"; }
err()  { echo -e "${c_r}✗ $*${c_0}"; }

[[ $EUID -eq 0 ]] || { err "Запусти от root"; exit 1; }

OUT="${1:-/root/3xui-backup-$(date +%F-%H%M).tar.gz}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/meta" "$TMP/db" "$TMP/etc/x-ui"

XUI_DB_TYPE=sqlite
XUI_DB_DSN=
[[ -f /etc/default/x-ui ]] && . /etc/default/x-ui
case "${XUI_DB_TYPE:-sqlite}" in
  postgres|postgresql|pg) XUI_DB_TYPE=postgres ;;
  *) XUI_DB_TYPE=sqlite ;;
esac

cp -a /etc/default/x-ui "$TMP/meta/x-ui.env" 2>/dev/null || true
{
  echo "format=cdn-vpn-export-v1"
  echo "created=$(date -Is)"
  echo "active_db=$XUI_DB_TYPE"
  echo "hostname=$(hostname -f 2>/dev/null || hostname)"
  echo "server_ip=$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
} > "$TMP/meta/type.txt"

HAVE_PG=0
HAVE_SQLITE=0
HAVE_THEME=0

parse_dsn() {
  local dsn="${1:-}"
  PG_USER=; PG_PASS=; PG_HOST=127.0.0.1; PG_PORT=5432; PG_DB=xui
  [[ "$dsn" =~ ^postgres(ql)?://([^:/@]+):([^@]+)@([^:/]+):([0-9]+)/([^?]+) ]] || return 1
  PG_USER="${BASH_REMATCH[2]}"; PG_PASS="${BASH_REMATCH[3]}"
  PG_HOST="${BASH_REMATCH[4]}"; PG_PORT="${BASH_REMATCH[5]}"; PG_DB="${BASH_REMATCH[6]}"
}

pg_counts() {
  PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -At -c \
    "SELECT (SELECT count(*) FROM inbounds)||' '||(SELECT count(*) FROM users)||' '||(SELECT count(*) FROM clients);" 2>/dev/null
}

sqlite_counts() {
  sqlite3 /etc/x-ui/x-ui.db \
    "SELECT (SELECT count(*) FROM inbounds)||' '||(SELECT count(*) FROM users)||' '||(SELECT count(*) FROM clients);" 2>/dev/null
}

say "${c_b}Экспорт 3x-ui${c_0} → $OUT"
say "Активный движок по /etc/default/x-ui: ${c_b}$XUI_DB_TYPE${c_0}"

# останавливаем панель, чтобы WAL/дамп были консистентны
systemctl stop x-ui 2>/dev/null || true
STOPPED=1

# --- Postgres ---
if [[ -n "${XUI_DB_DSN:-}" ]] && parse_dsn "$XUI_DB_DSN"; then
  if command -v pg_dump >/dev/null || apt-get install -y -qq postgresql-client >/dev/null; then
    say "Снимаю Postgres ${PG_DB}@${PG_HOST}:${PG_PORT} ..."
    if PGPASSWORD="$PG_PASS" pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -Fc -f "$TMP/db/xui-pg.dump"; then
      HAVE_PG=1
      counts=$(pg_counts || true)
      echo "postgres_counts_inbounds_users_clients=$counts" >> "$TMP/meta/type.txt"
      say "  Postgres: inbounds/users/clients = ${counts:-(н/д)}"
      [[ "${counts%% *}" =~ ^[1-9] ]] || warn "В Postgres 0 входящих"
      ok "Postgres → db/xui-pg.dump"
    else
      warn "pg_dump не удался — Postgres в архив не войдёт"
      rm -f "$TMP/db/xui-pg.dump"
    fi
  else
    warn "Нет pg_dump — Postgres пропущен"
  fi
elif [[ "$XUI_DB_TYPE" == postgres ]]; then
  warn "XUI_DB_TYPE=postgres, но XUI_DB_DSN пуст/битый — Postgres не снят"
fi

# --- SQLite (всегда, если файл есть — даже при активном Postgres) ---
if [[ -f /etc/x-ui/x-ui.db ]]; then
  command -v sqlite3 >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sqlite3 >/dev/null
  sqlite3 /etc/x-ui/x-ui.db "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
  cp -a /etc/x-ui/x-ui.db "$TMP/db/x-ui.db"
  # wal/shm после checkpoint обычно пустые, но на всякий случай
  [[ -f /etc/x-ui/x-ui.db-wal ]] && cp -a /etc/x-ui/x-ui.db-wal "$TMP/db/x-ui.db-wal"
  [[ -f /etc/x-ui/x-ui.db-shm ]] && cp -a /etc/x-ui/x-ui.db-shm "$TMP/db/x-ui.db-shm"
  HAVE_SQLITE=1
  counts=$(sqlite_counts || true)
  echo "sqlite_counts_inbounds_users_clients=$counts" >> "$TMP/meta/type.txt"
  say "  SQLite: inbounds/users/clients = ${counts:-(н/д)}"
  ok "SQLite → db/x-ui.db"
else
  say "SQLite /etc/x-ui/x-ui.db нет — пропуск"
fi

# --- sub-theme и прочие файлы панели (без огромных лишних копий db) ---
if [[ -d /etc/x-ui/sub-theme ]]; then
  mkdir -p "$TMP/etc/x-ui"
  cp -a /etc/x-ui/sub-theme "$TMP/etc/x-ui/"
  HAVE_THEME=1
  ok "Тема подписок → etc/x-ui/sub-theme/ ($(du -sh /etc/x-ui/sub-theme 2>/dev/null | awk '{print $1}'))"
else
  warn "Нет /etc/x-ui/sub-theme — пропуск"
fi

# остальные мелкие файлы из /etc/x-ui (не .db)
if [[ -d /etc/x-ui ]]; then
  while IFS= read -r -d '' f; do
    rel="${f#/etc/x-ui/}"
    case "$rel" in
      x-ui.db|x-ui.db-wal|x-ui.db-shm|sub-theme|sub-theme/*) continue ;;
    esac
    mkdir -p "$TMP/etc/x-ui/$(dirname "$rel")"
    cp -a "$f" "$TMP/etc/x-ui/$rel"
  done < <(find /etc/x-ui -mindepth 1 \( -type f -o -type l \) ! -name 'x-ui.db*' -print0 2>/dev/null)
fi

echo "have_postgres=$HAVE_PG" >> "$TMP/meta/type.txt"
echo "have_sqlite=$HAVE_SQLITE" >> "$TMP/meta/type.txt"
echo "have_sub_theme=$HAVE_THEME" >> "$TMP/meta/type.txt"

if [[ $STOPPED -eq 1 ]]; then
  systemctl start x-ui 2>/dev/null || true
fi

if [[ $HAVE_PG -eq 0 && $HAVE_SQLITE -eq 0 ]]; then
  err "Нечего бэкапить: ни Postgres, ни SQLite не найдены"
  exit 1
fi

# для совместимости со старым restore: дублируем пути
[[ $HAVE_PG -eq 1 ]] && cp -a "$TMP/db/xui-pg.dump" "$TMP/xui-pg.dump"
if [[ $HAVE_SQLITE -eq 1 ]]; then
  mkdir -p "$TMP/etc/x-ui"
  cp -a "$TMP/db/x-ui.db" "$TMP/etc/x-ui/x-ui.db"
  [[ -f "$TMP/db/x-ui.db-wal" ]] && cp -a "$TMP/db/x-ui.db-wal" "$TMP/etc/x-ui/x-ui.db-wal"
  [[ -f "$TMP/db/x-ui.db-shm" ]] && cp -a "$TMP/db/x-ui.db-shm" "$TMP/etc/x-ui/x-ui.db-shm"
fi

tar czf "$OUT" -C "$TMP" .
chmod 600 "$OUT"
ok "Архив: $OUT ($(du -h "$OUT" | awk '{print $1}'))"
say "Содержимое: postgres=$HAVE_PG  sqlite=$HAVE_SQLITE  sub-theme=$HAVE_THEME  active=$XUI_DB_TYPE"
IP=$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo SERVER)
say "Скачать:  ${c_b}scp root@${IP}:${OUT} .${c_0}"
say "На новый: ${c_b}scp $(basename "$OUT") root@НОВЫЙ_IP:/root/${c_0}"
say "Там:      ${c_b}bash cdn-vpn-setup.sh${c_0} → на шаге 3x-ui укажи этот архив"
