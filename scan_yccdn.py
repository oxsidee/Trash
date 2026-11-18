#!/usr/bin/env python3
"""Поиск живых Edge POP Yandex / Yandex Cloud CDN для cdn4.iscreation.ru.

Только стандартная библиотека Python 3. Запуск: python3 scan_yccdn.py
Рабочие адреса сразу дописываются в all_working_yccdn.txt.
"""
from __future__ import annotations

import base64
import gzip
import ipaddress
import json
import os
import random
import re
import resource
import socket
import ssl
import struct
import time
import urllib.parse
import zlib
from datetime import datetime, timedelta
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait

DOMAIN = "cdn4.iscreation.ru"
PORT = 443
WORKERS = 360
WINDOW = WORKERS * 2
CONNECT_TIMEOUT = 0.9
IO_TIMEOUT = 1.0
PROGRESS_EVERY = 25_000
MIN_PREFIXLEN = 12

OUT_PATH = "all_working_yccdn.txt"
CACHE_PATH = "yandex_prefixes_cache.json"
HISTORY_PATH = "scan_history.log"

ASNS = ("13238", "208722", "200350", "44534")

# Партнёрские подсети краевых узлов (не входят в ASN Яндекса).
PARTNER_PREFIXES = (
    "188.72.112.0/21",
    "95.163.248.0/21",
    "185.129.100.0/22",
    "185.206.164.0/22",
    "100.43.64.0/19",
)

# Крупные агрегаты Yandex Cloud.
YANDEX_CLOUD_PREFIXES = (
    "158.160.0.0/16",
    "51.250.0.0/17",
    "84.201.128.0/18",
    "89.169.128.0/18",
    "130.193.32.0/19",
    "178.154.192.0/19",
    "62.84.112.0/20",
    "84.252.128.0/18",
    "213.165.192.0/19",
)

# Крупные агрегаты основной сети AS13238.
AS13238_PREFIXES = (
    "5.45.192.0/18",
    "5.255.192.0/18",
    "37.9.64.0/18",
    "37.140.128.0/18",
    "77.88.0.0/18",
    "87.250.224.0/19",
    "93.158.128.0/18",
    "95.108.128.0/17",
    "141.8.128.0/18",
    "178.154.128.0/18",
    "213.180.192.0/19",
)

# Анонсы RIPE на 2026-11-18, которые не покрыты агрегатами выше
# (AS13238, AS200350, AS44534). AS208722 анонсирует только IPv6.
EXTRA_PREFIXES = (
    "92.255.112.0/20",
    "185.32.187.0/24",
    "153.51.160.0/19",
    "153.51.32.0/19",
    "153.51.96.0/19",
    "178.154.224.0/19",
    "93.77.160.0/19",
    "111.88.144.0/20",
    "111.88.240.0/20",
    "217.28.224.0/20",
    "81.26.176.0/20",
    "213.130.80.0/21",
    "217.198.168.0/21",
    "31.44.8.0/21",
    "103.76.52.0/22",
    "193.32.216.0/22",
    "37.230.172.0/22",
    "46.21.244.0/22",
    "37.230.168.0/23",
    "46.243.210.0/23",
    "46.243.209.0/24",
    "89.104.112.0/23",
    "194.247.51.0/24",
    "89.232.188.0/24",
    "89.232.189.0/24",
    "92.255.1.0/24",
    "92.255.3.0/24",
    "92.255.13.0/24",
    "92.255.15.0/24",
)

# DoH Яндекса говорит только HTTP/2. 77.88.8.8 — базовый резолвер (77.88.8.8 / 77.88.8.1).
YANDEX_DOH_IPS = ("77.88.8.8", "77.88.8.1")
YANDEX_DOH_HOST = "common.dot.dns.yandex.net"

CIDR_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}/\d{1,2}\b")
_RESOLVED: dict[str, str] = {}
TLS = ssl.create_default_context()


def raise_nofile(target: int = 65536) -> None:
    try:
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    except (OSError, ValueError, AttributeError):
        return
    limits = []
    if hard < target:
        limits.append((target, target))
    limits.append((min(target, max(hard, soft)), max(hard, target)))
    limits.append((max(soft, min(hard, target)), hard))
    for lim in limits:
        try:
            resource.setrlimit(resource.RLIMIT_NOFILE, lim)
            break
        except (OSError, ValueError):
            continue
    new_soft, new_hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    print(f"RLIMIT_NOFILE {soft} -> {new_soft} (hard {new_hard})", flush=True)


def dns_query(name: str) -> bytes:
    labels = b""
    for part in name.strip(".").split("."):
        raw = part.encode("idna")
        if not raw or len(raw) > 63:
            raise ValueError(name)
        labels += bytes([len(raw)]) + raw
    header = struct.pack("!HHHHHH", random.randrange(65536), 0x0100, 1, 0, 0, 0)
    return header + labels + b"\x00" + struct.pack("!HH", 1, 1)


def _skip_dns_name(msg: bytes, index: int) -> int:
    hops = 0
    while True:
        if index >= len(msg) or hops > 16:
            raise ValueError("битое DNS-имя")
        length = msg[index]
        hops += 1
        if length == 0:
            return index + 1
        if length & 0xC0 == 0xC0:
            if index + 1 >= len(msg):
                raise ValueError("битый DNS-указатель")
            return index + 2
        if length & 0xC0:
            raise ValueError("битая DNS-метка")
        index += 1 + length


def parse_dns_a(msg: bytes) -> list[str]:
    if len(msg) < 12:
        return []
    flags, qd, an, ns, ar = struct.unpack("!HHHHH", msg[2:12])
    if not flags & 0x8000 or flags & 0x000F:
        return []
    index = 12
    for _ in range(qd):
        index = _skip_dns_name(msg, index) + 4
    found: list[str] = []
    for _ in range(an + ns + ar):
        index = _skip_dns_name(msg, index)
        if index + 10 > len(msg):
            break
        typ, _cls, _ttl, rdlen = struct.unpack("!HHIH", msg[index : index + 10])
        index += 10
        rdata = msg[index : index + rdlen]
        index += rdlen
        if typ == 1 and len(rdata) == 4:
            found.append(socket.inet_ntoa(rdata))
    return found


def _frame(typ: int, flags: int, stream_id: int, payload: bytes = b"") -> bytes:
    if len(payload) > 16384:
        raise ValueError("h2 frame слишком большой")
    header = len(payload).to_bytes(3, "big") + bytes([typ, flags])
    header += (stream_id & 0x7FFFFFFF).to_bytes(4, "big")
    return header + payload


def _hpack_str(data: bytes) -> bytes:
    length = len(data)
    out = bytearray()
    if length < 127:
        out.append(length)
    else:
        out.append(127)
        length -= 127
        while length >= 128:
            out.append((length & 0x7F) | 0x80)
            length >>= 7
        out.append(length)
    out += data
    return bytes(out)


def _literal(name: str, value: str) -> bytes:
    return b"\x00" + _hpack_str(name.encode()) + _hpack_str(value.encode())


def _readn(sock: ssl.SSLSocket, size: int) -> bytes:
    buf = b""
    while len(buf) < size:
        chunk = sock.recv(size - len(buf))
        if not chunk:
            raise EOFError("обрыв HTTP/2")
        buf += chunk
    return buf


def h2_get(ip: str, host: str, path: str, timeout: float = 10) -> bytes:
    """Один HTTP/2 GET. Нужен для DoH Яндекса: HTTP/1.1 он закрывает без ответа."""
    ctx = ssl.create_default_context()
    ctx.set_alpn_protocols(["h2"])
    raw = socket.create_connection((ip, 443), timeout)
    tls: ssl.SSLSocket | None = None
    try:
        tls = ctx.wrap_socket(raw, server_hostname=host)
        tls.settimeout(timeout)
        if tls.selected_alpn_protocol() != "h2":
            raise OSError("сервер не выбрал h2")
        block = b"".join(
            (
                _literal(":method", "GET"),
                _literal(":scheme", "https"),
                _literal(":authority", host),
                _literal(":path", path),
                _literal("accept", "application/dns-message"),
            )
        )
        tls.sendall(
            b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
            + _frame(0x4, 0, 0)
            + _frame(0x1, 0x4 | 0x1, 1, block)
        )
        body = b""
        for _ in range(40):
            header = _readn(tls, 9)
            length = int.from_bytes(header[:3], "big")
            if length > 1_048_576:
                raise OSError("h2 frame слишком большой")
            typ, flags = header[3], header[4]
            payload = _readn(tls, length) if length else b""
            if typ == 0x4 and not flags & 0x1:
                tls.sendall(_frame(0x4, 0x1, 0))
            elif typ == 0x6 and not flags & 0x1:
                tls.sendall(_frame(0x6, 0x1, 0, payload))
            elif typ == 0x0:
                data = payload
                if flags & 0x8:
                    pad = data[0]
                    data = data[1 : len(data) - pad] if pad else data[1:]
                body += data
                if flags & 0x1:
                    return body
            elif typ == 0x1 and flags & 0x1:
                return body
            elif typ in (0x3, 0x7):
                raise OSError(f"HTTP/2 type {typ}")
        raise OSError("нет тела DoH")
    finally:
        try:
            (tls or raw).close()
        except OSError:
            pass


def udp_dns_a(ip: str, query: bytes, timeout: float = 2) -> list[str]:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.settimeout(timeout)
        sock.sendto(query, (ip, 53))
        data, _addr = sock.recvfrom(2048)
    finally:
        sock.close()
    return parse_dns_a(data)


def yandex_resolve(name: str) -> str:
    query = dns_query(name)
    token = base64.urlsafe_b64encode(query).rstrip(b"=").decode("ascii")
    path = "/dns-query?dns=" + token
    errors: list[str] = []
    for ip in YANDEX_DOH_IPS:
        try:
            ips = parse_dns_a(h2_get(ip, YANDEX_DOH_HOST, path))
            if ips:
                return ips[0]
            errors.append(f"DoH {ip}: нет A")
        except Exception as exc:
            errors.append(f"DoH {ip}: {exc}")
        try:
            ips = udp_dns_a(ip, query)
            if ips:
                print(f"DoH не ответил, взят UDP {ip}", flush=True)
                return ips[0]
            errors.append(f"UDP {ip}: нет A")
        except Exception as exc:
            errors.append(f"UDP {ip}: {exc}")
    raise OSError("; ".join(errors))


def is_dns_error(exc: BaseException) -> bool:
    seen: list[BaseException] = []
    cur: BaseException | None = exc
    while cur is not None and cur not in seen:
        seen.append(cur)
        if isinstance(cur, socket.gaierror):
            return True
        text = str(cur).lower()
        if (
            "nodename nor servname" in text
            or "name or service not known" in text
            or "temporary failure in name resolution" in text
            or "no address associated" in text
        ):
            return True
        cur = cur.__cause__ or cur.__context__
    return False


def resolve_host(host: str) -> str:
    cached = _RESOLVED.get(host)
    if cached:
        return cached
    try:
        ip = socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
        how = "системный DNS"
    except socket.gaierror as exc:
        print(f"DNS {host}: {exc}; запрос к Яндекс DoH", flush=True)
        ip = yandex_resolve(host)
        how = "Яндекс DoH"
    _RESOLVED[host] = ip
    print(f"{host} -> {ip} ({how})", flush=True)
    return ip


class _SNIConnection:
    """HTTPS к IP с SNI и Host исходного имени. Сертификат проверяется."""

    def __init__(self, ip: str, host: str, timeout: float) -> None:
        self._ip = ip
        self._host = host
        self._timeout = timeout
        self._tls: ssl.SSLSocket | None = None

    def get(self, path: str) -> tuple[int, str]:
        ctx = ssl.create_default_context()
        raw = socket.create_connection((self._ip, 443), self._timeout)
        try:
            self._tls = ctx.wrap_socket(raw, server_hostname=self._host)
            self._tls.settimeout(self._timeout)
            request = (
                f"GET {path} HTTP/1.1\r\n"
                f"Host: {self._host}\r\n"
                "User-Agent: yccdn-scan\r\n"
                "Accept: */*\r\n"
                "Connection: close\r\n\r\n"
            )
            self._tls.sendall(request.encode("ascii"))
            data = b""
            while True:
                chunk = self._tls.recv(65536)
                if not chunk:
                    break
                data += chunk
                if len(data) > 8_000_000:
                    raise OSError("ответ слишком большой")
        finally:
            try:
                (self._tls or raw).close()
            except OSError:
                pass
        head, _, body = data.partition(b"\r\n\r\n")
        line = head.split(b"\r\n", 1)[0].decode("iso-8859-1", "replace")
        parts = line.split()
        if len(parts) < 2 or not parts[0].startswith("HTTP/"):
            raise OSError(f"нет статуса от {self._host}")
        return int(parts[1]), body.decode("utf-8", "replace")


def https_get(url: str, timeout: float = 25) -> str:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ValueError(url)
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    try:
        ip = resolve_host(parsed.hostname)
    except socket.gaierror:
        raise
    status, text = _SNIConnection(ip, parsed.hostname, timeout).get(path)
    if status != 200:
        raise OSError(f"{parsed.hostname} вернул {status}")
    return text


def parse_ripe(text: str) -> list[str]:
    data = json.loads(text)
    if data.get("status") != "ok":
        raise OSError(data.get("status") or "ripe")
    found = []
    for row in data.get("data", {}).get("prefixes", []):
        prefix = row.get("prefix")
        if prefix and ":" not in prefix:
            found.append(prefix)
    return found


def parse_bgpview(text: str) -> list[str]:
    data = json.loads(text)
    if data.get("status") not in (None, "ok"):
        raise OSError(data.get("status_message") or data.get("status"))
    rows = (data.get("data") or {}).get("ipv4_prefixes") or []
    return [row["prefix"] for row in rows if row.get("prefix")]


def parse_hackertarget(text: str) -> list[str]:
    lowered = text.lower()
    if "exceeded" in lowered or (lowered.startswith("error") and "/" not in text):
        raise OSError(text.strip()[:180] or "hackertarget")
    found = CIDR_RE.findall(text)
    if not found:
        raise OSError(text.strip()[:180] or "пустой ответ")
    return found


def fetch_asn(asn: str) -> tuple[list[str], bool]:
    # bgpview.io закрылся в ноябре 2025 и часто не резолвится — тогда берётся HackerTarget.
    sources = (
        ("ripe", f"https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS{asn}&min_peers_seeing=1", parse_ripe),
        ("bgpview", f"https://api.bgpview.io/asn/{asn}/prefixes", parse_bgpview),
        ("hackertarget", f"https://api.hackertarget.com/aslookup/?q=AS{asn}", parse_hackertarget),
    )
    for name, url, parser in sources:
        try:
            prefixes = parser(https_get(url))
        except Exception as exc:
            print(f"AS{asn}: {name} недоступен ({exc})", flush=True)
            continue
        print(f"AS{asn}: {name}, IPv4-префиксов {len(prefixes)}", flush=True)
        return prefixes, True
    print(f"AS{asn}: онлайн-источники недоступны, остаётся суперкэш", flush=True)
    return [], False


def parse_net(text: str) -> ipaddress.IPv4Network | None:
    try:
        net = ipaddress.ip_network(text.strip(), strict=False)
    except ValueError:
        return None
    if net.version != 4 or not net.is_global:
        return None
    if net.prefixlen < MIN_PREFIXLEN:
        return None
    return net


def load_cache() -> list[str]:
    try:
        with open(CACHE_PATH, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return []
    prefixes = data.get("prefixes") if isinstance(data, dict) else None
    if not isinstance(prefixes, list):
        return []
    return [item for item in prefixes if isinstance(item, str)]


def save_cache(nets: list[ipaddress.IPv4Network]) -> None:
    payload = {
        "domain": DOMAIN,
        "prefixes": [str(net) for net in nets],
    }
    tmp = CACHE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=1)
        handle.write("\n")
    os.replace(tmp, CACHE_PATH)
    print(f"кэш записан: {CACHE_PATH} ({len(nets)} подсетей)", flush=True)


def collect_networks() -> list[ipaddress.IPv4Network]:
    texts = [
        *PARTNER_PREFIXES,
        *YANDEX_CLOUD_PREFIXES,
        *AS13238_PREFIXES,
        *EXTRA_PREFIXES,
        *load_cache(),
    ]
    online = False
    for asn in ASNS:
        prefixes, ok = fetch_asn(asn)
        if ok:
            online = True
            texts.extend(prefixes)
    nets = [net for net in (parse_net(item) for item in texts) if net is not None]
    collapsed = list(ipaddress.collapse_addresses(nets))
    if online:
        save_cache(collapsed)
    else:
        print("онлайн-загрузка не удалась, сканируется суперкэш и файл кэша", flush=True)
    return collapsed


def host_count(net: ipaddress.IPv4Network) -> int:
    if net.prefixlen >= 31:
        return net.num_addresses
    return net.num_addresses - 2


def iter_addrs(nets: list[ipaddress.IPv4Network]):
    for net in nets:
        for ip in net.hosts():
            yield str(ip)


def http_ok(buf: bytes) -> bool:
    line = buf.split(b"\r\n", 1)[0].decode("iso-8859-1", "replace")
    parts = line.split()
    return len(parts) >= 2 and parts[0].startswith("HTTP/") and parts[1] == "200"


def probe(ip: str) -> tuple[str, int] | None:
    started = time.perf_counter()
    raw: socket.socket | None = None
    tls: ssl.SSLSocket | None = None
    try:
        raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        raw.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        raw.settimeout(CONNECT_TIMEOUT)
        raw.connect((ip, PORT))
        raw.settimeout(IO_TIMEOUT)
        tls = TLS.wrap_socket(raw, server_hostname=DOMAIN)
        raw = None
        tls.sendall(
            f"HEAD / HTTP/1.1\r\nHost: {DOMAIN}\r\nConnection: close\r\n\r\n".encode("ascii")
        )
        buf = b""
        while b"\r\n" not in buf and len(buf) < 128:
            chunk = tls.recv(128 - len(buf))
            if not chunk:
                break
            buf += chunk
        if not http_ok(buf):
            return None
        return ip, int(round((time.perf_counter() - started) * 1000))
    except Exception:
        return None
    finally:
        sock = tls or raw
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass


def _shutdown(pool: ThreadPoolExecutor, wait_for: bool, cancel: bool) -> None:
    if cancel:
        try:
            pool.shutdown(wait=wait_for, cancel_futures=True)
            return
        except TypeError:
            pass
    pool.shutdown(wait=wait_for)


def scan(nets: list[ipaddress.IPv4Network], total: int) -> list[tuple[str, int]]:
    pending: set = set()
    checked = 0
    found = 0
    hits: list[tuple[str, int]] = []
    mark = 0
    started = time.monotonic()
    pool = ThreadPoolExecutor(max_workers=WORKERS, thread_name_prefix="yccdn")
    addresses = iter_addrs(nets)
    exhausted = False
    interrupted = False
    out = open(OUT_PATH, "a", encoding="utf-8", buffering=1)
    try:
        while pending or not exhausted:
            while not exhausted and len(pending) < WINDOW:
                try:
                    pending.add(pool.submit(probe, next(addresses)))
                except StopIteration:
                    exhausted = True
            if not pending:
                break
            done, pending = wait(pending, return_when=FIRST_COMPLETED)
            for future in done:
                checked += 1
                hit = future.result()
                if hit is not None:
                    ip, ms = hit
                    found += 1
                    hits.append((ip, ms))
                    _show_hit(ip, ms)
                    out.write(f"{ip} {ms}ms\n")
                    out.flush()
                    os.fsync(out.fileno())
                    _progress(checked, total, found, started, stay=True)
                step = checked // PROGRESS_EVERY
                if step > mark:
                    mark = step
                    _progress(checked, total, found, started, stay=False)
                elif checked % 500 == 0:
                    _progress(checked, total, found, started, stay=True)
        if checked % PROGRESS_EVERY:
            _progress(checked, total, found, started, stay=False)
        return hits
    except KeyboardInterrupt:
        interrupted = True
        print(f"\nпрервано на {checked}/{total}, найдено {found}", flush=True)
        return hits
    finally:
        try:
            out.flush()
            os.fsync(out.fileno())
        except OSError:
            pass
        out.close()
        _shutdown(pool, not interrupted, interrupted)
        if interrupted:
            os._exit(130)


def _show_hit(ip: str, ms: int) -> None:
    line = f"{ip} {ms}ms"
    if os.isatty(1):
        print(f"\r\033[K\033[1;32m{line}\033[0m", flush=True)
    else:
        print(f"\r\033[K{line}", flush=True)


def _progress(checked: int, total: int, found: int, started: float, *, stay: bool) -> None:
    elapsed = max(time.monotonic() - started, 0.001)
    pct = (100.0 * checked / total) if total else 100.0
    text = f"{pct:5.1f}%  {checked}/{total}  {checked / elapsed:.0f} ip/s  найдено {found}"
    if stay:
        print(f"\r{text}", end="", flush=True)
    else:
        print(f"\r\033[K{text}", flush=True)


def _env_file(path: str) -> dict[str, str]:
    found: dict[str, str] = {}
    try:
        handle = open(path, encoding="utf-8")
    except OSError:
        return found
    with handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            value = value.strip().strip("'\"")
            found[key.strip()] = value
    return found


def edge_config() -> tuple[str, str, str] | None:
    file_vars: dict[str, str] = {}
    for path in (
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "cdn-edge.env"),
        "cdn-edge.env",
    ):
        file_vars.update(_env_file(path))
    url = os.environ.get("CDN_EDGE_URL", file_vars.get("CDN_EDGE_URL", "")).strip()
    token = os.environ.get("CDN_EDGE_TOKEN", file_vars.get("CDN_EDGE_TOKEN", "")).strip()
    write_url = os.environ.get("CDN_EDGE_WRITE_URL", file_vars.get("CDN_EDGE_WRITE_URL", "")).strip()
    if not url or not token:
        return None
    return url, token, write_url


def known_edge_ips() -> list[str]:
    ips: list[str] = []
    try:
        lines = open(OUT_PATH, encoding="utf-8")
    except OSError:
        return ips
    with lines:
        for line in lines:
            part = line.split()
            if part and is_public_ipv4(part[0]) and part[0] not in ips:
                ips.append(part[0])
    return ips


def is_public_ipv4(value: str) -> bool:
    try:
        addr = ipaddress.ip_address(value)
    except ValueError:
        return False
    return addr.version == 4 and addr.is_global


def choose_edge(addresses: list[str], hits: list[tuple[str, int]]) -> str | None:
    """IP с минимальной задержкой, либо None если текущие адреса и так среди живых."""
    if not hits:
        return None
    found = {ip for ip, _ms in hits}
    if addresses and all(is_public_ipv4(item) and item in found for item in addresses):
        return None
    return min(hits, key=lambda item: (item[1], item[0]))[0]


def _recv_some(sock: ssl.SSLSocket, size: int) -> bytes:
    try:
        return sock.recv(size)
    except socket.timeout:
        return b""


def _read_chunked(sock: ssl.SSLSocket, pending: bytes) -> bytes:
    out = b""
    data = pending
    while True:
        while b"\r\n" not in data:
            chunk = _recv_some(sock, 4096)
            if not chunk:
                return out
            data += chunk
        line, _, data = data.partition(b"\r\n")
        try:
            size = int(line.split(b";", 1)[0], 16)
        except ValueError as exc:
            raise OSError("битый chunked") from exc
        if size == 0:
            return out
        while len(data) < size + 2:
            chunk = _recv_some(sock, size + 2 - len(data))
            if not chunk:
                return out
            data += chunk
        out += data[:size]
        data = data[size + 2 :]


def _decode_body(headers: dict[str, str], body: bytes) -> bytes:
    encoding = headers.get("content-encoding", "")
    if "gzip" in encoding:
        return gzip.decompress(body)
    if "deflate" in encoding:
        try:
            return zlib.decompress(body)
        except zlib.error:
            return zlib.decompress(body, -zlib.MAX_WBITS)
    return body


def _read_http(tls: ssl.SSLSocket) -> tuple[int, dict]:
    data = b""
    while b"\r\n\r\n" not in data and len(data) < 65536:
        chunk = _recv_some(tls, 4096)
        if not chunk:
            break
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    line = head.split(b"\r\n", 1)[0].decode("iso-8859-1", "replace")
    parts = line.split()
    if len(parts) < 2 or not parts[0].startswith("HTTP/"):
        raise OSError("нет статуса API")
    status = int(parts[1])
    headers: dict[str, str] = {}
    for raw in head.split(b"\r\n")[1:]:
        if b":" in raw:
            key, value = raw.split(b":", 1)
            headers[key.decode().lower()] = value.strip().decode()
    if "chunked" in headers.get("transfer-encoding", "").lower():
        body = _read_chunked(tls, rest)
    else:
        body = rest
        need = int(headers.get("content-length", "0") or "0")
        while len(body) < need:
            chunk = _recv_some(tls, need - len(body))
            if not chunk:
                break
            body += chunk
        if need == 0 and not body:
            while True:
                chunk = _recv_some(tls, 4096)
                if not chunk:
                    break
                body += chunk
                if len(body) > 1_000_000:
                    break
    body = _decode_body(headers, body)
    text = body.decode("utf-8", "replace").lstrip("\ufeff").strip()
    if not text:
        raise OSError(f"HTTP {status}, пустой ответ")
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as exc:
        snippet = " ".join(text.split())[:160]
        raise OSError(f"HTTP {status}, не JSON: {snippet}") from exc
    if not isinstance(payload, dict):
        raise OSError("ответ API не объект")
    return status, payload


def edge_exchange(
    url: str,
    token: str,
    method: str,
    via: str | None = None,
    payload: dict | None = None,
    timeout: float = 20,
) -> dict:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ValueError(url)
    path = parsed.path or "/"
    query = parsed.query
    if method == "GET":
        stamp = f"t={int(time.time() * 1000)}"
        query = f"{query}&{stamp}" if query else stamp
    if query:
        path = f"{path}?{query}"
    ip = via or resolve_host(parsed.hostname)
    raw = socket.create_connection((ip, parsed.port or 443), timeout)
    tls: ssl.SSLSocket | None = None
    try:
        tls = ssl.create_default_context().wrap_socket(raw, server_hostname=parsed.hostname)
        tls.settimeout(timeout)
        body = b""
        extra = ""
        if payload is not None:
            body = json.dumps(payload).encode()
            extra = f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n"
        request = (
            f"{method} {path} HTTP/1.1\r\n"
            f"Host: {parsed.hostname}\r\n"
            f"X-Edge-Token: {token}\r\n"
            f"Authorization: Bearer {token}\r\n"
            f"Accept: application/json\r\n"
            "Accept-Encoding: identity\r\n"
            f"{extra}"
            "Connection: close\r\n\r\n"
        ).encode() + body
        tls.sendall(request)
        status, data = _read_http(tls)
    finally:
        try:
            (tls or raw).close()
        except OSError:
            pass
    if status != 200:
        raise OSError(data.get("error") or f"HTTP {status}")
    return data


def edge_get(url: str, token: str, vias: list[str]) -> tuple[bool, list[str], str | None]:
    attempts: list[str | None] = [None, *vias[:5]]
    last = "нет маршрута"
    for via in attempts:
        try:
            data = edge_exchange(url, token, "GET", via)
        except Exception as exc:
            last = str(exc)
            continue
        addresses = [str(item) for item in data.get("addresses") or [] if str(item)]
        where = via or "DNS"
        print(f"3x-ui сейчас: {', '.join(addresses) or 'пусто'} (через {where})", flush=True)
        return True, addresses, via
    print(f"текущий адрес 3x-ui не прочитан ({last})", flush=True)
    return False, [], None


def write_target(url: str) -> str:
    parsed = urllib.parse.urlsplit(url.strip())
    if parsed.scheme != "https" or not parsed.hostname:
        raise ValueError("CDN_EDGE_WRITE_URL должен быть https://хост")
    path = parsed.path or "/"
    if path == "/":
        path = "/_edge/v1"
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, path, parsed.query, ""))


def edge_apply(
    url: str,
    token: str,
    hits: list[tuple[str, int]],
    via: str | None,
    write_url: str,
) -> str:
    if not hits:
        print("живых IP нет, 3x-ui не меняю", flush=True)
        return "живых IP нет, 3x-ui не менялся"
    vias = [ip for ip, _ms in sorted(hits, key=lambda item: item[1])]
    if via and via not in vias:
        vias.insert(0, via)
    ok, addresses, _route = edge_get(url, token, vias)
    if not ok:
        print("сервер не ответил, 3x-ui не меняю", flush=True)
        return "сервер не ответил, 3x-ui не менялся"
    chosen = choose_edge(addresses, hits)
    if chosen is None:
        print("текущий IP уже среди живых, не меняю", flush=True)
        return "текущий IP уже среди живых"
    if not write_url:
        print("CDN_EDGE_WRITE_URL не задан, 3x-ui не меняю", flush=True)
        return "CDN_EDGE_WRITE_URL не задан, 3x-ui не менялся"
    try:
        target = write_target(write_url)
    except ValueError as exc:
        print(f"не записал {chosen}: {exc}", flush=True)
        return f"не записал {chosen}"
    print(f"пишу {chosen} на {target}", flush=True)
    try:
        result = edge_exchange(target, token, "POST", None, {"address": chosen})
    except Exception as exc:
        print(f"не записал {chosen} через {target}: {exc}", flush=True)
        return f"не записал {chosen}"
    ms = next(ms for ip, ms in hits if ip == chosen)
    line = f"3x-ui → {chosen} {ms}ms"
    if os.isatty(1):
        print(f"\033[1;32m{line}\033[0m", flush=True)
    else:
        print(line, flush=True)
    if not result.get("restarted", True):
        print("база записана, но x-ui не перезапустился", flush=True)
    return line


def remember(summary: str) -> None:
    now = datetime.now()
    line = now.strftime("%Y-%m-%d %H:%M:%S") + " " + summary
    print(line, flush=True)
    cutoff = now - timedelta(days=2)
    kept: list[str] = []
    try:
        previous = open(HISTORY_PATH, encoding="utf-8")
    except OSError:
        previous = None
    if previous is not None:
        with previous:
            for item in previous:
                item = item.strip()
                try:
                    stamp = datetime.strptime(item[:19], "%Y-%m-%d %H:%M:%S")
                except ValueError:
                    continue
                if stamp >= cutoff:
                    kept.append(item)
    kept.append(line)
    with open(HISTORY_PATH, "w", encoding="utf-8") as handle:
        handle.write("\n".join(kept) + "\n")


def run_full_scan(cfg: tuple[str, str, str] | None, via: str | None) -> None:
    before = set(known_edge_ips())
    nets = collect_networks()
    total = sum(host_count(net) for net in nets)
    print(f"к сканированию: {len(nets)} подсетей, {total} адресов", flush=True)
    if total <= 0:
        remember("полное сканирование не началось: нет адресов")
        return
    hits = scan(nets, total)
    fresh = sum(1 for ip, _ms in hits if ip not in before)
    print(f"готово, найдено {len(hits)}, новых {fresh}. Файл: {OUT_PATH}", flush=True)
    if cfg is None:
        remember(f"полное сканирование, найдено {len(hits)}, новых {fresh}, 3x-ui не менялся")
        return
    result = edge_apply(cfg[0], cfg[1], hits, via, cfg[2])
    remember(f"полное сканирование, найдено {len(hits)}, новых {fresh}, {result}")


def main() -> None:
    raise_nofile()
    print(datetime.now().strftime("%Y-%m-%d %H:%M:%S"), flush=True)
    print(
        f"{DOMAIN}:443, потоков {WORKERS}, TCP-таймаут {CONNECT_TIMEOUT} с",
        flush=True,
    )
    cfg = edge_config()
    if cfg is None:
        print("CDN_EDGE_URL и CDN_EDGE_TOKEN не заданы, сервер не меняю", flush=True)
        run_full_scan(None, None)
        return
    ok, addresses, via = edge_get(cfg[0], cfg[1], known_edge_ips())
    if not ok:
        remember("не прочитан адрес 3x-ui, сканирование не запускалось")
        return
    current = [item for item in addresses if is_public_ipv4(item)]
    if not current:
        shown = ", ".join(addresses) or "пусто"
        print(f"в 3x-ui нет IP ({shown}), полное сканирование", flush=True)
        run_full_scan(cfg, via)
        return
    alive: list[tuple[str, int]] = []
    for ip in current:
        hit = probe(ip)
        if hit is None:
            print(f"{ip} недоступен, полное сканирование", flush=True)
            run_full_scan(cfg, via)
            return
        alive.append(hit)
        _show_hit(*hit)
    remember("оставил " + ", ".join(f"{ip} {ms}ms" for ip, ms in alive))


if __name__ == "__main__":
    main()
