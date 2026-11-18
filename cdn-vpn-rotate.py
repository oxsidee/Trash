#!/usr/bin/env python3
"""Ротация CDN-доменов для 3x-ui (hosts + downloadSettings).

Читает/пишет SQLite или Postgres. Вызов:
  CDN_ZONE=iscreation.ru CDN_PREFIX=cdn \\
    python3 cdn-vpn-rotate.py [--start N] [--dry-run] [--db sqlite|/path|postgres]

Без --start: MAX из текущих доменов → uplink=cdn{MAX+1}, download=cdn{MAX+2}.
cdn.iscreation.ru без номера считается как 1.
С --start 10: uplink=cdn10, download=cdn11.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
from copy import deepcopy
from typing import Any
from urllib.parse import unquote, urlparse


def env_zone() -> tuple[str, str]:
    prefix = os.environ.get("CDN_PREFIX", "cdn").strip() or "cdn"
    zone = os.environ.get("CDN_ZONE", "iscreation.ru").strip() or "iscreation.ru"
    return prefix, zone


def domain_re(prefix: str, zone: str) -> re.Pattern[str]:
    # cdn.iscreation.ru → 1; cdn12.iscreation.ru → 12
    z = re.escape(zone)
    p = re.escape(prefix)
    return re.compile(rf"(?i)\b{p}(\d*)\.{z}\b")


def parse_num(text: str | None, prefix: str, zone: str) -> int | None:
    if not text:
        return None
    m = domain_re(prefix, zone).search(str(text))
    if not m:
        return None
    digits = m.group(1)
    return int(digits) if digits else 1


def make_domain(n: int, prefix: str, zone: str) -> str:
    return f"{prefix}{n}.{zone}"


def collect_max(texts: list[str | None], prefix: str, zone: str) -> int:
    nums = [parse_num(t, prefix, zone) for t in texts]
    found = [n for n in nums if n is not None]
    return max(found) if found else 1


def dig(obj: Any, *path: str) -> Any:
    cur = obj
    for p in path:
        if not isinstance(cur, dict) or p not in cur:
            return None
        cur = cur[p]
    return cur


def ensure_dict(parent: dict, key: str) -> dict:
    v = parent.get(key)
    if not isinstance(v, dict):
        v = {}
        parent[key] = v
    return v


def parse_stream(raw: Any) -> dict:
    """stream_settings из SQLite — строка; из Postgres jsonb — уже dict."""
    if raw is None or raw == "":
        return {}
    if isinstance(raw, dict):
        return deepcopy(raw)
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode("utf-8", errors="replace")
    if isinstance(raw, str):
        try:
            obj = json.loads(raw)
        except Exception as e:
            raise ValueError(f"Не разобрать stream_settings JSON: {e}") from e
        return obj if isinstance(obj, dict) else {}
    raise ValueError(f"Неожиданный тип stream_settings: {type(raw)}")


def find_download_settings(stream: dict) -> dict:
    """Вернуть downloadSettings внутри xhttpSettings (каноничное место для 3x-ui).

    Если блок был в xhttpSettings.extra.downloadSettings — переносим наверх.
    """
    xhttp = ensure_dict(stream, "xhttpSettings")
    if isinstance(xhttp.get("downloadSettings"), dict):
        return xhttp["downloadSettings"]

    extra = xhttp.get("extra") if isinstance(xhttp.get("extra"), dict) else None
    if extra is not None and isinstance(extra.get("downloadSettings"), dict):
        ds = extra.pop("downloadSettings")
        xhttp["downloadSettings"] = ds
        return ds

    ds: dict = {}
    xhttp["downloadSettings"] = ds
    return ds


def extract_download_domains(stream_raw: Any, prefix: str, zone: str) -> list[str]:
    out: list[str] = []
    try:
        stream = parse_stream(stream_raw)
    except Exception:
        return out
    xhttp = stream.get("xhttpSettings") if isinstance(stream.get("xhttpSettings"), dict) else {}
    candidates = []
    for container in (xhttp, xhttp.get("extra") if isinstance(xhttp.get("extra"), dict) else {}):
        if not isinstance(container, dict):
            continue
        ds = container.get("downloadSettings")
        if not isinstance(ds, dict):
            continue
        candidates.extend(
            [
                ds.get("address"),
                dig(ds, "tlsSettings", "serverName"),
                dig(ds, "xhttpSettings", "host"),
            ]
        )
    return [str(c) for c in candidates if c]


def patch_download_settings(
    stream_raw: Any,
    download_domain: str,
    *,
    path_fallback: str = "/",
) -> str:
    """Гарантирует разделение uplink/download в точности как в рабочей схеме:

    xhttpSettings.downloadSettings = {
      address, port, network, security,
      tlsSettings: {serverName, fingerprint, alpn},
      xhttpSettings: {host, path, mode, xPaddingBytes}
    }
    """
    stream = parse_stream(stream_raw)

    xhttp = ensure_dict(stream, "xhttpSettings")
    path = xhttp.get("path") or path_fallback
    mode = xhttp.get("mode") or "packet-up"

    ds = find_download_settings(stream)

    # точная структура разделения потоков
    ds["address"] = download_domain
    try:
        port = int(ds.get("port", 443))
    except (TypeError, ValueError):
        port = 443
    ds["port"] = port if port > 0 else 443
    ds["network"] = "xhttp"
    ds["security"] = "tls"

    tls = ensure_dict(ds, "tlsSettings")
    tls["serverName"] = download_domain
    tls["fingerprint"] = tls.get("fingerprint") or "chrome"
    if not isinstance(tls.get("alpn"), list) or not tls.get("alpn"):
        tls["alpn"] = ["h2", "http/1.1"]

    dx = ensure_dict(ds, "xhttpSettings")
    dx["host"] = download_domain
    dx["path"] = dx.get("path") or path
    dx["mode"] = dx.get("mode") or mode
    # как у рабочей схемы — на верхнем уровне download.xhttpSettings, не в extra
    if not dx.get("xPaddingBytes"):
        if isinstance(dx.get("extra"), dict) and dx["extra"].get("xPaddingBytes"):
            dx["xPaddingBytes"] = dx["extra"].pop("xPaddingBytes")
        else:
            dx["xPaddingBytes"] = "100-1000"
    # убрать пустой extra
    if isinstance(dx.get("extra"), dict) and not dx["extra"]:
        dx.pop("extra", None)

    # каноничное место — только xhttpSettings.downloadSettings
    xhttp["downloadSettings"] = ds
    if isinstance(xhttp.get("extra"), dict):
        xhttp["extra"].pop("downloadSettings", None)
        if not xhttp["extra"]:
            xhttp.pop("extra", None)

    return json.dumps(stream, ensure_ascii=False, separators=(",", ":"))


def download_settings_ok(stream_raw: Any, expect_domain: str) -> bool:
    try:
        st = parse_stream(stream_raw)
    except Exception:
        return False
    ds = dig(st, "xhttpSettings", "downloadSettings")
    if not isinstance(ds, dict):
        return False
    return (
        ds.get("address") == expect_domain
        and dig(ds, "tlsSettings", "serverName") == expect_domain
        and dig(ds, "xhttpSettings", "host") == expect_domain
    )

# --- DB backends ---

def parse_pg_dsn(dsn: str) -> dict:
    u = urlparse(dsn)
    if u.scheme not in ("postgres", "postgresql"):
        raise SystemExit(f"Не Postgres DSN: {dsn}")
    return {
        "user": unquote(u.username or ""),
        "password": unquote(u.password or ""),
        "host": u.hostname or "127.0.0.1",
        "port": u.port or 5432,
        "dbname": (u.path or "/xui").lstrip("/") or "xui",
    }


class Store:
    def list_hosts(self) -> list[dict]:
        raise NotImplementedError

    def list_inbounds(self) -> list[dict]:
        raise NotImplementedError

    def update_host(self, host_id: int, remark: str, address: str, sni: str | None) -> None:
        raise NotImplementedError

    def update_inbound_stream(self, inbound_id: int, stream_settings: str) -> None:
        raise NotImplementedError

    def close(self) -> None:
        pass


class SqliteStore(Store):
    def __init__(self, path: str):
        if not os.path.isfile(path):
            raise SystemExit(f"Нет SQLite БД: {path}")
        self.conn = sqlite3.connect(path)
        self.conn.row_factory = sqlite3.Row

    def list_hosts(self) -> list[dict]:
        cur = self.conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='hosts'"
        )
        if not cur.fetchone():
            return []
        rows = self.conn.execute(
            "SELECT id, inbound_id, remark, address, sni, override_sni_from_address, "
            "is_disabled, host_header FROM hosts"
        ).fetchall()
        return [dict(r) for r in rows]

    def _stream_cols(self) -> list[str]:
        cols = {r[1] for r in self.conn.execute("PRAGMA table_info(inbounds)").fetchall()}
        found = [c for c in ("stream_settings", "streamSettings") if c in cols]
        return found or ["stream_settings"]

    def list_inbounds(self) -> list[dict]:
        ss = self._stream_cols()[0]
        rows = self.conn.execute(
            f"SELECT id, remark, tag, {ss} AS stream_settings FROM inbounds"
        ).fetchall()
        return [dict(r) for r in rows]

    def update_host(self, host_id: int, remark: str, address: str, sni: str | None) -> None:
        if sni is None:
            self.conn.execute(
                "UPDATE hosts SET remark=?, address=? WHERE id=?",
                (remark, address, host_id),
            )
        else:
            self.conn.execute(
                "UPDATE hosts SET remark=?, address=?, sni=? WHERE id=?",
                (remark, address, sni, host_id),
            )

    def update_inbound_stream(self, inbound_id: int, stream_settings: str) -> None:
        # пишем во все варианты имени колонки, если вдруг оба есть
        for ss in self._stream_cols():
            self.conn.execute(
                f"UPDATE inbounds SET {ss}=? WHERE id=?",
                (stream_settings, inbound_id),
            )

    def commit(self) -> None:
        self.conn.commit()

    def close(self) -> None:
        self.conn.close()


class PostgresStore(Store):
    def __init__(self, dsn: str):
        try:
            import psycopg2
            import psycopg2.extras
        except ImportError:
            # fallback: use subprocess psql — but prefer psycopg2
            raise SystemExit(
                "Нужен python3-psycopg2 (apt install python3-psycopg2) для Postgres"
            ) from None
        self.psycopg2 = psycopg2
        self.extras = psycopg2.extras
        kw = parse_pg_dsn(dsn)
        self.conn = psycopg2.connect(**kw)
        self.conn.autocommit = False

    def list_hosts(self) -> list[dict]:
        with self.conn.cursor(cursor_factory=self.extras.RealDictCursor) as cur:
            cur.execute(
                "SELECT EXISTS (SELECT 1 FROM information_schema.tables "
                "WHERE table_name='hosts')"
            )
            if not cur.fetchone()["exists"]:
                return []
            cur.execute(
                "SELECT id, inbound_id, remark, address, sni, override_sni_from_address, "
                "is_disabled, host_header FROM hosts"
            )
            return [dict(r) for r in cur.fetchall()]

    def _stream_col_meta(self) -> list[tuple[str, str]]:
        """[(column_name, udt_name), ...] для stream_settings / streamSettings."""
        with self.conn.cursor() as cur:
            cur.execute(
                "SELECT column_name, udt_name FROM information_schema.columns "
                "WHERE table_schema='public' AND table_name='inbounds' "
                "AND column_name IN ('stream_settings','streamSettings')"
            )
            rows = [(r[0], r[1]) for r in cur.fetchall()]
        if not rows:
            return [("stream_settings", "text")]
        # предпочитаем stream_settings первым
        order = {"stream_settings": 0, "streamSettings": 1}
        rows.sort(key=lambda x: order.get(x[0], 9))
        return rows

    def _stream_cols(self) -> list[str]:
        return [c for c, _ in self._stream_col_meta()]

    def list_inbounds(self) -> list[dict]:
        ss = self._stream_cols()[0]
        with self.conn.cursor(cursor_factory=self.extras.RealDictCursor) as cur:
            cur.execute(
                f"SELECT id, remark, tag, {ss} AS stream_settings FROM inbounds"
            )
            return [dict(r) for r in cur.fetchall()]

    def update_host(self, host_id: int, remark: str, address: str, sni: str | None) -> None:
        with self.conn.cursor() as cur:
            if sni is None:
                cur.execute(
                    "UPDATE hosts SET remark=%s, address=%s WHERE id=%s",
                    (remark, address, host_id),
                )
            else:
                cur.execute(
                    "UPDATE hosts SET remark=%s, address=%s, sni=%s WHERE id=%s",
                    (remark, address, sni, host_id),
                )

    def update_inbound_stream(self, inbound_id: int, stream_settings: str) -> None:
        obj = json.loads(stream_settings)
        with self.conn.cursor() as cur:
            for col, udt in self._stream_col_meta():
                if udt in ("json", "jsonb"):
                    # jsonb: пишем объект, не JSON-строку (иначе двойное экранирование)
                    cur.execute(
                        f"UPDATE inbounds SET {col}=%s WHERE id=%s",
                        (self.extras.Json(obj), inbound_id),
                    )
                else:
                    cur.execute(
                        f"UPDATE inbounds SET {col}=%s WHERE id=%s",
                        (stream_settings, inbound_id),
                    )

    def commit(self) -> None:
        self.conn.commit()

    def close(self) -> None:
        self.conn.close()


def open_store(args: argparse.Namespace) -> Store:
    db = args.db
    if db == "auto":
        env_path = "/etc/default/x-ui"
        db_type = "sqlite"
        dsn = ""
        if os.path.isfile(env_path):
            for line in open(env_path, encoding="utf-8", errors="ignore"):
                line = line.strip()
                if line.startswith("XUI_DB_TYPE="):
                    db_type = line.split("=", 1)[1].strip().strip("'\"")
                elif line.startswith("XUI_DB_DSN="):
                    dsn = line.split("=", 1)[1].strip().strip("'\"")
        if db_type.lower() in ("postgres", "postgresql", "pg") and dsn:
            return PostgresStore(dsn)
        return SqliteStore("/etc/x-ui/x-ui.db")
    if db.startswith("postgres"):
        return PostgresStore(db if "://" in db else os.environ.get("XUI_DB_DSN", ""))
    return SqliteStore(db)


def main() -> int:
    ap = argparse.ArgumentParser(description="Ротация CDN-доменов 3x-ui")
    ap.add_argument(
        "--start",
        type=int,
        default=None,
        metavar="N",
        help="Номер uplink вручную (cdnN / cdnN+1). Без флага — MAX+1 / MAX+2",
    )
    ap.add_argument(
        "--ensure-split",
        action="store_true",
        help="Не ротировать hosts: только восстановить downloadSettings "
        "(download = номер uplink-хоста + 1)",
    )
    ap.add_argument(
        "--show-split",
        action="store_true",
        help="Только показать downloadSettings из БД (не из xray config.json)",
    )
    ap.add_argument("--dry-run", action="store_true", help="Только показать, не писать")
    ap.add_argument(
        "--db",
        default="auto",
        help="auto | путь к sqlite | postgres DSN",
    )
    ap.add_argument(
        "--inbound-id",
        type=int,
        default=None,
        help="Ограничить одним inbound id (по умолчанию — все xhttp)",
    )
    ap.add_argument(
        "--host-id",
        type=int,
        default=None,
        help="Ограничить одним host id (по умолчанию — все подходящие)",
    )
    args = ap.parse_args()
    prefix, zone = env_zone()

    store = open_store(args)
    try:
        hosts = store.list_hosts()
        inbounds = store.list_inbounds()

        if args.show_split:
            found = 0
            for ib in inbounds:
                raw = ib.get("stream_settings")
                try:
                    st = parse_stream(raw)
                except Exception as e:
                    print(f"inbound id={ib['id']} tag={ib.get('tag')}: parse error: {e}")
                    continue
                ds = dig(st, "xhttpSettings", "downloadSettings")
                print(f"inbound id={ib['id']} tag={ib.get('tag')} network={st.get('network')}")
                if isinstance(ds, dict) and ds:
                    found += 1
                    print(json.dumps({"downloadSettings": ds}, ensure_ascii=False, indent=2))
                else:
                    extra_ds = dig(st, "xhttpSettings", "extra", "downloadSettings")
                    if isinstance(extra_ds, dict) and extra_ds:
                        found += 1
                        print("  (в extra.downloadSettings — лучше перенести через ensure-split)")
                        print(json.dumps({"downloadSettings": extra_ds}, ensure_ascii=False, indent=2))
                    else:
                        print("  downloadSettings: ОТСУТСТВУЕТ")
            if found == 0:
                print(
                    "Нет downloadSettings в БД. "
                    "Не смотри config.json — там его вырезает x-ui. Запусти: ensure-split",
                    file=sys.stderr,
                )
                return 1
            print(
                f"ok: найдено inbound с downloadSettings: {found}. "
                "В UI/config.json блока не видно — это нормально."
            )
            return 0

        texts: list[str | None] = []
        for h in hosts:
            texts.extend([h.get("remark"), h.get("address"), h.get("sni"), h.get("host_header")])
        for ib in inbounds:
            texts.append(ib.get("remark"))
            texts.append(ib.get("tag"))
            texts.extend(extract_download_domains(ib.get("stream_settings"), prefix, zone))
            try:
                st = parse_stream(ib.get("stream_settings"))
                texts.append(dig(st, "tlsSettings", "serverName"))
                texts.append(dig(st, "xhttpSettings", "host"))
            except Exception:
                pass

        cur_max = collect_max(texts, prefix, zone)

        if args.ensure_split:
            # uplink = текущий адрес хоста (не бампим); download = uplink+1
            host_nums = []
            for h in hosts:
                if h.get("is_disabled"):
                    continue
                for k in ("address", "remark", "sni"):
                    n = parse_num(h.get(k), prefix, zone)
                    if n is not None:
                        host_nums.append(n)
            up_n = max(host_nums) if host_nums else cur_max
            if args.start is not None:
                if args.start < 1:
                    raise SystemExit("--start должен быть >= 1")
                up_n = args.start
            downlink_n = up_n + 1
            uplink = make_domain(up_n, prefix, zone)
            download = make_domain(downlink_n, prefix, zone)
            print(f"mode=ensure-split")
            print(f"zone={prefix}.*.{zone}")
            print(f"uplink(keep)={uplink}")
            print(f"download={download}")
            host_updates = []
        else:
            if args.start is not None:
                if args.start < 1:
                    raise SystemExit("--start должен быть >= 1")
                up_n = args.start
            else:
                up_n = cur_max + 1
            downlink_n = up_n + 1
            uplink = make_domain(up_n, prefix, zone)
            download = make_domain(downlink_n, prefix, zone)

            print(f"zone={prefix}.*.{zone}")
            print(f"current_max={cur_max}")
            print(f"uplink={uplink}")
            print(f"download={download}")

            host_updates = []
            for h in hosts:
                if args.host_id is not None and int(h["id"]) != args.host_id:
                    continue
                if h.get("is_disabled"):
                    continue
                related = any(
                    parse_num(h.get(k), prefix, zone) is not None
                    for k in ("address", "remark", "sni", "host_header")
                )
                if not related and len(hosts) > 1:
                    continue
                override = bool(h.get("override_sni_from_address"))
                new_sni = None if override else uplink
                host_updates.append((h, new_sni))

            if not host_updates and hosts:
                for h in hosts:
                    if not h.get("is_disabled"):
                        override = bool(h.get("override_sni_from_address"))
                        host_updates.append((h, None if override else uplink))
                        break

            for h, new_sni in host_updates:
                print(
                    f"host id={h['id']}: remark/address "
                    f"{h.get('remark')!r}/{h.get('address')!r} → {uplink}"
                    + (f", sni → {new_sni}" if new_sni else " (sni from address)")
                )
                if not args.dry_run:
                    store.update_host(int(h["id"]), uplink, uplink, new_sni)

        # inbounds: всегда гарантируем downloadSettings (разделение потоков)
        ib_updates = 0
        for ib in inbounds:
            if args.inbound_id is not None and int(ib["id"]) != args.inbound_id:
                continue
            raw = ib.get("stream_settings")
            try:
                st = parse_stream(raw)
            except Exception as e:
                print(f"inbound id={ib['id']}: skip ({e})", file=sys.stderr)
                continue
            if st.get("network") != "xhttp" and "xhttpSettings" not in st:
                has_ds = bool(dig(st, "xhttpSettings", "downloadSettings")) or bool(
                    dig(st, "xhttpSettings", "extra", "downloadSettings")
                )
                if not has_ds:
                    continue

            new_raw = patch_download_settings(raw, download)
            print(f"inbound id={ib['id']} tag={ib.get('tag')}: downloadSettings → {download}")
            # показать ключевые поля
            after = json.loads(new_raw)
            ds = dig(after, "xhttpSettings", "downloadSettings") or {}
            print(
                f"  address={ds.get('address')}  "
                f"serverName={dig(ds, 'tlsSettings', 'serverName')}  "
                f"host={dig(ds, 'xhttpSettings', 'host')}  "
                f"path={dig(ds, 'xhttpSettings', 'path')}"
            )
            if not args.dry_run:
                store.update_inbound_stream(int(ib["id"]), new_raw)
            ib_updates += 1

        if not host_updates and ib_updates == 0:
            print("Нечего обновлять: нет hosts/inbounds", file=sys.stderr)
            return 1

        if args.dry_run:
            print("dry-run: изменений не записано")
        else:
            store.commit()
            # перечитать и проверить, что блок на месте (ловит jsonb/column баги)
            store2 = open_store(args)
            try:
                bad = 0
                for ib in store2.list_inbounds():
                    if args.inbound_id is not None and int(ib["id"]) != args.inbound_id:
                        continue
                    raw = ib.get("stream_settings")
                    try:
                        st = parse_stream(raw)
                    except Exception:
                        continue
                    if st.get("network") != "xhttp" and "xhttpSettings" not in st:
                        continue
                    if not download_settings_ok(raw, download):
                        print(
                            f"VERIFY FAIL inbound id={ib['id']}: downloadSettings нет или не {download}",
                            file=sys.stderr,
                        )
                        bad += 1
                    else:
                        print(f"verify ok inbound id={ib['id']}")
                if bad:
                    print(
                        "error: downloadSettings не сохранился в БД — проверь колонку stream_settings",
                        file=sys.stderr,
                    )
                    return 2
            finally:
                store2.close()
            print("ok: записано в БД, разделение uplink/download на месте")
        return 0
    finally:
        store.close()


if __name__ == "__main__":
    raise SystemExit(main())
