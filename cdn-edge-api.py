#!/usr/bin/env python3
"""Локальный API: текущий адрес хоста 3x-ui и замена его на IP краевого узла.

Слушает только 127.0.0.1. Снаружи его открывает nginx (cdn-edge-install.sh).
Токен: файл /etc/cdn-edge/token, заголовок X-Edge-Token.
"""
from __future__ import annotations

import hmac
import importlib.util
import ipaddress
import json
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import SimpleNamespace

PATH = "/_edge/v1"
HERE = os.path.dirname(os.path.abspath(__file__))


def load_rotate():
    path = os.path.join(HERE, "cdn-vpn-rotate.py")
    spec = importlib.util.spec_from_file_location("cdn_vpn_rotate", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"нет {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ROTATE = load_rotate()


def read_token() -> str:
    path = os.environ.get("CDN_EDGE_TOKEN_FILE", "/etc/cdn-edge/token")
    with open(path, encoding="utf-8") as handle:
        token = handle.read().strip()
    if len(token) < 16:
        raise RuntimeError("токен слишком короткий")
    return token


def read_state() -> dict[str, str]:
    path = os.environ.get("CDN_EDGE_STATE", "/root/.cdn-vpn.env")
    out: dict[str, str] = {}
    try:
        lines = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return out
    with lines as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
            out[key] = value
    return out


def zone_name() -> str:
    state = read_state()
    zone = state.get("CDN_ZONE", "").strip()
    if zone:
        return zone
    domain = state.get("CDN_DOMAIN", "").strip()
    parts = domain.split(".")
    if len(parts) >= 2:
        return ".".join(parts[1:])
    return "iscreation.ru"


def is_ipv4(value: object) -> bool:
    try:
        return ipaddress.ip_address(str(value).strip()).version == 4
    except ValueError:
        return False


def public_ipv4(value: str) -> str:
    try:
        addr = ipaddress.ip_address(value.strip())
    except ValueError as exc:
        raise ValueError("нужен IPv4") from exc
    if addr.version != 4 or not addr.is_global:
        raise ValueError("нужен публичный IPv4")
    return str(addr)


def domain_of(host: dict, zone: str) -> str | None:
    pattern = re.compile(r"([a-z0-9-]+\.)+" + re.escape(zone), re.I)
    for key in ("sni", "host_header", "address", "remark"):
        text = str(host.get(key) or "")
        if is_ipv4(text):
            continue
        match = pattern.search(text)
        if match:
            return match.group(0).lower()
    return None


def our_hosts(hosts: list[dict], zone: str) -> list[dict]:
    picked = []
    for host in hosts:
        if host.get("is_disabled"):
            continue
        blob = " ".join(
            str(host.get(key) or "")
            for key in ("address", "remark", "sni", "host_header")
        ).lower()
        if zone.lower() in blob:
            picked.append(host)
    if picked:
        return picked
    enabled = [host for host in hosts if not host.get("is_disabled")]
    if len(enabled) == 1:
        return enabled
    return []


def open_store():
    db = os.environ.get("CDN_EDGE_DB", "auto")
    return ROTATE.open_store(SimpleNamespace(db=db))


def column_names(store) -> set[str]:
    if store.__class__.__name__ == "SqliteStore":
        rows = store.conn.execute("PRAGMA table_info(hosts)").fetchall()
        return {row[1] for row in rows}
    with store.conn.cursor() as cur:
        cur.execute(
            "SELECT column_name FROM information_schema.columns WHERE table_name='hosts'"
        )
        return {row[0] for row in cur.fetchall()}


def bool_false(store, column: str):
    if store.__class__.__name__ == "SqliteStore":
        return 0
    with store.conn.cursor() as cur:
        cur.execute(
            "SELECT data_type FROM information_schema.columns "
            "WHERE table_name='hosts' AND column_name=%s",
            (column,),
        )
        row = cur.fetchone()
    if row and row[0] == "boolean":
        return False
    return 0


def read_addresses() -> dict:
    zone = zone_name()
    store = open_store()
    try:
        hosts = our_hosts(store.list_hosts(), zone)
        if not hosts:
            raise LookupError("в 3x-ui нет хоста этой зоны")
        addresses = [str(host.get("address") or "") for host in hosts]
        sni = next((domain_of(host, zone) for host in hosts if domain_of(host, zone)), "")
        return {"addresses": addresses, "sni": sni}
    finally:
        store.close()


def apply_address(ip: str) -> dict:
    ip = public_ipv4(ip)
    zone = zone_name()
    store = open_store()
    try:
        hosts = our_hosts(store.list_hosts(), zone)
        if not hosts:
            raise LookupError("в 3x-ui нет хоста этой зоны")
        cols = column_names(store)
        placeholder = "?" if store.__class__.__name__ == "SqliteStore" else "%s"
        updated = 0
        for host in hosts:
            domain = domain_of(host, zone)
            sets = ["address=" + placeholder]
            values: list = [ip]
            if "override_sni_from_address" in cols:
                sets.append("override_sni_from_address=" + placeholder)
                values.append(bool_false(store, "override_sni_from_address"))
            if domain and "sni" in cols and (not host.get("sni") or is_ipv4(host.get("sni"))):
                sets.append("sni=" + placeholder)
                values.append(domain)
            header = str(host.get("host_header") or "")
            if domain and "host_header" in cols and (not header or is_ipv4(header)):
                sets.append("host_header=" + placeholder)
                values.append(domain)
            values.append(int(host["id"]))
            sql = f"UPDATE hosts SET {', '.join(sets)} WHERE id={placeholder}"
            if store.__class__.__name__ == "SqliteStore":
                store.conn.execute(sql, values)
            else:
                with store.conn.cursor() as cur:
                    cur.execute(sql, values)
            updated += 1
        store.commit()
    except Exception:
        try:
            store.conn.rollback()
        except Exception:
            pass
        raise
    finally:
        store.close()
    restarted = restart_xui()
    return {"address": ip, "updated": updated, "restarted": restarted}


def restart_xui() -> bool:
    if os.environ.get("CDN_EDGE_NO_RESTART") == "1":
        return True
    try:
        proc = subprocess.run(
            ["systemctl", "restart", "x-ui"],
            check=False,
            timeout=40,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"restart x-ui: {exc}", file=sys.stderr)
        return False
    if proc.returncode != 0:
        print(proc.stderr.strip() or f"systemctl {proc.returncode}", file=sys.stderr)
        return False
    return True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        return

    def _authorized(self) -> bool:
        sent = self.headers.get("X-Edge-Token", "")
        if not sent:
            auth = self.headers.get("Authorization", "")
            if auth.lower().startswith("bearer "):
                sent = auth[7:].strip()
        return bool(sent) and hmac.compare_digest(sent, read_token())

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _route(self, body: bytes | None) -> None:
        if self.path.split("?", 1)[0] != PATH:
            self._send(404, {"error": "not found"})
            return
        if not self._authorized():
            self._send(401, {"error": "unauthorized"})
            return
        try:
            if self.command == "GET":
                self._send(200, read_addresses())
                return
            if self.command == "POST":
                data = json.loads(body or b"{}")
                result = apply_address(str(data.get("address", "")))
                self._send(200, result)
                return
        except LookupError as exc:
            self._send(409, {"error": str(exc)})
            return
        except (ValueError, json.JSONDecodeError) as exc:
            self._send(400, {"error": str(exc)})
            return
        except Exception as exc:
            self._send(500, {"error": str(exc)})
            return
        self._send(405, {"error": "method"})

    def do_GET(self) -> None:
        self._route(None)

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length > 1024:
            self._send(400, {"error": "body"})
            return
        self._route(self.rfile.read(length))


def main() -> None:
    host = os.environ.get("CDN_EDGE_BIND", "127.0.0.1")
    port = int(os.environ.get("CDN_EDGE_PORT", "8791"))
    read_token()
    httpd = ThreadingHTTPServer((host, port), Handler)
    print(f"cdn-edge-api {host}:{port}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
