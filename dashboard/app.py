#!/usr/bin/env python3
"""
Pusat Kendali — dashboard ringan untuk server pribadi.
Hanya memakai pustaka standar Python (tanpa dependensi) supaya image kecil dan mudah diaudit.

Fitur:
  * login admin (sesi cookie HttpOnly + SameSite=Strict, pembatasan percobaan gagal)
  * statistik host: CPU, RAM, disk, load, uptime (dibaca dari /proc host)
  * daftar layanan stack + CPU/RAM per container
  * start / stop / restart container dan lihat log
Semua akses Docker lewat docker-socket-proxy yang hanya mengizinkan baca + start/stop/restart.
"""
import hashlib
import hmac
import http.client
import json
import os
import re
import secrets
import socket
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlparse

# ----------------------------------------------------------------- konfigurasi
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")
DOCKER_HOST = os.environ.get("DOCKER_HOST", "tcp://socket-proxy:2375")
PROJECT = os.environ.get("COMPOSE_PROJECT", "serverku")
MODE = os.environ.get("MODE", "local")
DOMAIN = os.environ.get("DOMAIN", "")
HOST_ADDR = os.environ.get("HOST_ADDR", "localhost")
HOST_PROC = os.environ.get("HOST_PROC", "/host/proc")
PORT = int(os.environ.get("PORT", "8000"))
REFRESH_SEC = float(os.environ.get("REFRESH_SEC", "5"))
SESSION_TTL = 12 * 3600
MAX_FAILS, LOCK_SEC = 5, 600
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/static/app.js": ("app.js", "application/javascript; charset=utf-8"),
    "/static/style.css": ("style.css", "text/css; charset=utf-8"),
}
# Layanan yang tidak boleh dimatikan dari panel (kalau mati, panel ikut terputus)
PROTECTED = {"dashboard", "socket-proxy", "traefik", "cloudflared"}

# key = nama service di docker-compose
META = {
    "dashboard":    {"title": "Pusat Kendali", "desc": "Panel yang sedang kamu buka", "sub": "panel", "port": 8000, "scheme": "http", "group": "Inti"},
    "portainer":    {"title": "Portainer", "desc": "Kelola container, image, volume & network", "sub": "portainer", "port": 9443, "scheme": "https", "group": "Inti"},
    "code":         {"title": "VS Code", "desc": "Coding langsung dari browser (code-server)", "sub": "code", "port": 8080, "scheme": "http", "group": "Kerja"},
    "jupyter":      {"title": "JupyterLab", "desc": "Notebook Python & data science", "sub": "jupyter", "port": 8888, "scheme": "http", "group": "Kerja"},
    "nextcloud":    {"title": "Nextcloud", "desc": "Cloud storage pribadi, pengganti Google Drive", "sub": "cloud", "port": 8081, "scheme": "http", "group": "Data"},
    "adminer":      {"title": "Adminer", "desc": "Kelola database PostgreSQL lewat web", "sub": "db", "port": 8082, "scheme": "http", "group": "Data"},
    "postgres":     {"title": "PostgreSQL", "desc": "Database utama (localhost:5432)", "group": "Data"},
    "redis":        {"title": "Redis", "desc": "Cache untuk Nextcloud", "group": "Data"},
    "uptime-kuma":  {"title": "Uptime Kuma", "desc": "Pemantau status + notifikasi", "sub": "status", "port": 3001, "scheme": "http", "group": "Pantau"},
    "netdata":      {"title": "Netdata", "desc": "Monitoring detail real-time", "sub": "monitor", "port": 19999, "scheme": "http", "group": "Pantau"},
    "socket-proxy": {"title": "Socket Proxy", "desc": "Gerbang aman ke Docker API", "group": "Inti"},
    "traefik":      {"title": "Traefik", "desc": "Reverse proxy + HTTPS otomatis", "group": "Inti"},
    "cloudflared":  {"title": "Cloudflare Tunnel", "desc": "Jalur aman ke internet tanpa buka port", "group": "Inti"},
}

ID_RE = re.compile(r"^[a-f0-9]{12,64}$")


def log(*a):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *a, flush=True)


# ----------------------------------------------------------------- docker client
class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self._path = path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self._path)
        self.sock = s


class Docker:
    def __init__(self, host):
        u = urlparse(host if "://" in host else "tcp://" + host)
        self.unix = u.path if u.scheme == "unix" else None
        self.addr = (u.hostname or "localhost", u.port or 2375)

    def request(self, method, path, timeout=10):
        if self.unix:
            conn = UnixHTTPConnection(self.unix, timeout)
        else:
            conn = http.client.HTTPConnection(*self.addr, timeout=timeout)
        try:
            conn.request(method, path, headers={"Host": "docker"})
            r = conn.getresponse()
            return r.status, r.read()
        finally:
            conn.close()

    def get_json(self, path, timeout=10):
        status, body = self.request("GET", path, timeout)
        if status != 200:
            raise RuntimeError(f"docker {path} -> {status}")
        return json.loads(body)


docker = Docker(DOCKER_HOST)


# ----------------------------------------------------------------- statistik host
class HostStats:
    def __init__(self):
        self.prev = None

    def _read(self, name):
        with open(os.path.join(HOST_PROC, name)) as f:
            return f.read()

    def snapshot(self):
        out = {}
        try:
            lines = self._read("stat").splitlines()
            vals = list(map(int, lines[0].split()[1:]))
            idle, total = vals[3] + (vals[4] if len(vals) > 4 else 0), sum(vals[:8])
            cores = sum(1 for l in lines if re.match(r"cpu\d+ ", l))
            pct = None
            if self.prev and total > self.prev[1]:
                pct = round(100 * (1 - (idle - self.prev[0]) / (total - self.prev[1])), 1)
            self.prev = (idle, total)
            out["cpu"] = {"percent": pct, "cores": cores}
        except Exception as e:
            out["cpu"] = {"error": str(e)}
        try:
            mi = {}
            for l in self._read("meminfo").splitlines():
                k, v = l.split(":", 1)
                mi[k] = int(v.split()[0]) * 1024
            total, avail = mi["MemTotal"], mi.get("MemAvailable", mi.get("MemFree", 0))
            out["memory"] = {"total": total, "used": total - avail,
                             "percent": round(100 * (total - avail) / total, 1),
                             "swap_total": mi.get("SwapTotal", 0),
                             "swap_used": mi.get("SwapTotal", 0) - mi.get("SwapFree", 0)}
        except Exception as e:
            out["memory"] = {"error": str(e)}
        try:
            out["load"] = [float(x) for x in self._read("loadavg").split()[:3]]
            out["uptime"] = int(float(self._read("uptime").split()[0]))
        except Exception:
            out["load"], out["uptime"] = None, None
        try:
            st = os.statvfs("/")
            total, free = st.f_blocks * st.f_frsize, st.f_bavail * st.f_frsize
            out["disk"] = {"total": total, "used": total - free, "percent": round(100 * (total - free) / total, 1)}
        except Exception as e:
            out["disk"] = {"error": str(e)}
        return out


# ----------------------------------------------------------------- kolektor latar belakang
def service_url(service):
    m = META.get(service, {})
    if not m.get("sub"):
        return None
    if MODE in ("domain", "tunnel") and DOMAIN:
        return f"https://{DOMAIN}" if service == "dashboard" else f"https://{m['sub']}.{DOMAIN}"
    return f"{m['scheme']}://{HOST_ADDR}:{m['port']}"


def calc_stats(s):
    try:
        cpu, pre = s["cpu_stats"], s["precpu_stats"]
        cd = cpu["cpu_usage"]["total_usage"] - pre["cpu_usage"]["total_usage"]
        sd = cpu.get("system_cpu_usage", 0) - pre.get("system_cpu_usage", 0)
        n = cpu.get("online_cpus") or len(cpu["cpu_usage"].get("percpu_usage") or []) or 1
        cpu_pct = round(cd / sd * n * 100, 1) if sd > 0 and cd >= 0 else 0.0
    except Exception:
        cpu_pct = None
    try:
        m = s["memory_stats"]
        st = m.get("stats", {})
        used = m["usage"] - st.get("inactive_file", st.get("cache", 0))
        mem = {"used": used, "limit": m.get("limit")}
    except Exception:
        mem = None
    return {"cpu": cpu_pct, "mem": mem}


class Collector(threading.Thread):
    daemon = True

    def __init__(self):
        super().__init__()
        self.host = HostStats()
        self.pool = ThreadPoolExecutor(max_workers=8)
        self.lock = threading.Lock()
        self.data = {"host": {}, "services": [], "docker_ok": False, "error": "memuat…", "ts": 0}
        self.ids = set()

    def collect(self):
        host = self.host.snapshot()
        try:
            filt = quote(json.dumps({"label": [f"com.docker.compose.project={PROJECT}"]}))
            containers = docker.get_json(f"/containers/json?all=1&filters={filt}")
            running = [c for c in containers if c.get("State") == "running"]
            stats = dict(zip([c["Id"] for c in running],
                             self.pool.map(self._stats, [c["Id"] for c in running])))
            services = []
            for c in containers:
                svc = c.get("Labels", {}).get("com.docker.compose.service", c["Names"][0].lstrip("/"))
                m = META.get(svc, {})
                services.append({
                    "id": c["Id"][:12], "service": svc,
                    "title": m.get("title", svc), "desc": m.get("desc", c.get("Image", "")),
                    "group": m.get("group", "Lainnya"),
                    "image": c.get("Image"), "state": c.get("State"), "status": c.get("Status"),
                    "created": c.get("Created"), "url": service_url(svc),
                    "protected": svc in PROTECTED,
                    "stats": stats.get(c["Id"]),
                })
            order = list(META)
            services.sort(key=lambda s: (order.index(s["service"]) if s["service"] in order else 99, s["service"]))
            with self.lock:
                self.ids = {c["Id"] for c in containers}
                self.data = {"host": host, "services": services, "docker_ok": True, "error": None, "ts": time.time()}
        except Exception as e:
            with self.lock:
                self.data = {**self.data, "host": host, "docker_ok": False, "error": f"Docker API tidak terjangkau: {e}", "ts": time.time()}

    def _stats(self, cid):
        try:
            return calc_stats(docker.get_json(f"/containers/{cid}/stats?stream=false", timeout=8))
        except Exception:
            return None

    def resolve(self, short_id):
        """Hanya container milik stack ini yang boleh disentuh."""
        if not ID_RE.match(short_id or ""):
            return None
        with self.lock:
            for full in self.ids:
                if full.startswith(short_id):
                    return full
        return None

    def service_of(self, short_id):
        with self.lock:
            for s in self.data["services"]:
                if s["id"] == short_id[:12]:
                    return s
        return None

    def run(self):
        while True:
            t0 = time.time()
            self.collect()
            time.sleep(max(0.5, REFRESH_SEC - (time.time() - t0)))


collector = Collector()


def demux_logs(raw):
    """Docker mengirim log non-TTY dengan header 8 byte per frame."""
    if len(raw) >= 8 and raw[0] in (0, 1, 2) and raw[1:4] == b"\x00\x00\x00":
        out, i = [], 0
        while i + 8 <= len(raw):
            size = int.from_bytes(raw[i + 4:i + 8], "big")
            out.append(raw[i + 8:i + 8 + size])
            i += 8 + size
        raw = b"".join(out)
    return raw.decode("utf-8", "replace")


# ----------------------------------------------------------------- sesi & login
SESSIONS = {}
FAILS = {}
AUTH_LOCK = threading.Lock()


def check_password(user, pw):
    a = hmac.compare_digest(hashlib.sha256(user.encode()).digest(), hashlib.sha256(ADMIN_USER.encode()).digest())
    b = hmac.compare_digest(hashlib.sha256(pw.encode()).digest(), hashlib.sha256(ADMIN_PASSWORD.encode()).digest())
    return a and b


# ----------------------------------------------------------------- HTTP handler
class Handler(BaseHTTPRequestHandler):
    server_version = "PusatKendali/1.0"
    sys_version = ""

    def log_message(self, fmt, *args):
        if "/api/overview" not in (args[0] if args else ""):
            log(self.client_ip(), fmt % args)

    def client_ip(self):
        if MODE == "tunnel" and self.headers.get("CF-Connecting-IP"):
            return self.headers["CF-Connecting-IP"].strip()
        if MODE == "domain":
            xff = self.headers.get("X-Forwarded-For")
            if xff:
                return xff.split(",")[-1].strip()
        return self.client_address[0]

    def send(self, code, body=b"", ctype="application/json; charset=utf-8", headers=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def session(self):
        cookie = self.headers.get("Cookie", "")
        m = re.search(r"(?:^|;\s*)pk_session=([A-Za-z0-9_\-]+)", cookie)
        if not m:
            return None
        with AUTH_LOCK:
            exp = SESSIONS.get(m.group(1))
            if exp and exp > time.time():
                return m.group(1)
            SESSIONS.pop(m.group(1), None)
        return None

    def read_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 10_000:
            return None
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return None

    # -------------------------------------------------------------- GET
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/healthz":
            return self.send(200, {"ok": True})
        if path in STATIC_FILES:
            fname, ctype = STATIC_FILES[path]
            with open(os.path.join(STATIC_DIR, fname), "rb") as f:
                return self.send(200, f.read(), ctype)
        if path == "/api/session":
            return self.send(200, {"authenticated": bool(self.session()), "user": ADMIN_USER if self.session() else None})
        if not path.startswith("/api/"):
            return self.send(404, {"error": "tidak ditemukan"})
        if not self.session():
            return self.send(401, {"error": "silakan login"})
        if path == "/api/overview":
            with collector.lock:
                d = dict(collector.data)
            d.update({"project": PROJECT, "mode": MODE, "domain": DOMAIN, "host_addr": HOST_ADDR})
            return self.send(200, d)
        m = re.match(r"^/api/services/([a-f0-9]{12})/logs$", path)
        if m:
            full = collector.resolve(m.group(1))
            if not full:
                return self.send(404, {"error": "container tidak dikenal"})
            q = parse_qs(urlparse(self.path).query)
            t = (q.get("tail") or ["300"])[0]
            tail = max(10, min(2000, int(t))) if t.isdigit() else 300
            status, raw = docker.request("GET", f"/containers/{full}/logs?stdout=1&stderr=1&timestamps=1&tail={tail}", timeout=15)
            if status != 200:
                return self.send(502, {"error": f"gagal membaca log ({status})"})
            return self.send(200, {"logs": demux_logs(raw)})
        return self.send(404, {"error": "tidak ditemukan"})

    do_HEAD = do_GET

    # -------------------------------------------------------------- POST
    def do_POST(self):
        path = urlparse(self.path).path
        if self.headers.get("X-Requested-With") != "pusat-kendali":
            return self.send(403, {"error": "permintaan ditolak"})
        ip = self.client_ip()

        if path == "/api/login":
            now = time.time()
            with AUTH_LOCK:
                fails = [t for t in FAILS.get(ip, []) if now - t < LOCK_SEC]
                FAILS[ip] = fails
            if len(fails) >= MAX_FAILS:
                wait = int(LOCK_SEC - (now - fails[0]))
                return self.send(429, {"error": f"Terlalu banyak percobaan. Coba lagi dalam {wait // 60 + 1} menit."})
            body = self.read_json() or {}
            if check_password(str(body.get("username", "")), str(body.get("password", ""))):
                token = secrets.token_urlsafe(32)
                with AUTH_LOCK:
                    SESSIONS[token] = now + SESSION_TTL
                    FAILS.pop(ip, None)
                secure = "; Secure" if self.headers.get("X-Forwarded-Proto") == "https" else ""
                log(ip, "login berhasil")
                return self.send(200, {"ok": True, "user": ADMIN_USER}, headers={
                    "Set-Cookie": f"pk_session={token}; HttpOnly; SameSite=Strict; Path=/; Max-Age={SESSION_TTL}{secure}"})
            with AUTH_LOCK:
                FAILS.setdefault(ip, []).append(now)
            log(ip, "login GAGAL")
            time.sleep(0.8)  # perlambat brute force
            return self.send(401, {"error": "Username atau password salah."})

        token = self.session()
        if not token:
            return self.send(401, {"error": "silakan login"})

        if path == "/api/logout":
            with AUTH_LOCK:
                SESSIONS.pop(token, None)
            return self.send(200, {"ok": True}, headers={"Set-Cookie": "pk_session=; Max-Age=0; Path=/; HttpOnly; SameSite=Strict"})

        m = re.match(r"^/api/services/([a-f0-9]{12})/(start|stop|restart)$", path)
        if m:
            sid, action = m.groups()
            full = collector.resolve(sid)
            svc = collector.service_of(sid)
            if not full or not svc:
                return self.send(404, {"error": "container tidak dikenal"})
            if svc["protected"] and action == "stop":
                return self.send(400, {"error": f"{svc['title']} dilindungi — mematikannya akan memutus panel ini."})
            q = "?t=10" if action in ("stop", "restart") else ""
            status, body = docker.request("POST", f"/containers/{full}/{action}{q}", timeout=40)
            log(ip, f"{action} {svc['service']} -> {status}")
            if status in (204, 304):
                threading.Thread(target=collector.collect, daemon=True).start()
                return self.send(200, {"ok": True})
            return self.send(502, {"error": f"Docker menolak ({status}): {body[:200].decode('utf-8', 'replace')}"})

        return self.send(404, {"error": "tidak ditemukan"})


def main():
    if len(ADMIN_PASSWORD) < 12:
        log("FATAL: ADMIN_PASSWORD kosong/terlalu pendek (min 12). Jalankan ./install.sh untuk membuatnya.")
        sys.exit(1)
    collector.start()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    srv.daemon_threads = True
    log(f"Pusat Kendali aktif di :{PORT} (proyek={PROJECT}, mode={MODE}, docker={DOCKER_HOST})")
    srv.serve_forever()


if __name__ == "__main__":
    main()
