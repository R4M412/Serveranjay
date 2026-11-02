#!/usr/bin/env python3
"""
Docker Engine API tiruan untuk menguji Pusat Kendali TANPA Docker.
Meniru endpoint yang diizinkan docker-socket-proxy: list, stats, logs, start/stop/restart.
  python3 dev/mock_docker.py 2375
"""
import json, random, re, sys, time, hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROJECT = "serverku"
SERVICES = [
    ("dashboard", "serverku/dashboard:local"), ("socket-proxy", "tecnativa/docker-socket-proxy:latest"),
    ("portainer", "portainer/portainer-ce:lts"), ("code", "codercom/code-server:latest"),
    ("jupyter", "quay.io/jupyter/scipy-notebook:latest"), ("postgres", "postgres:16-alpine"),
    ("adminer", "adminer:latest"), ("redis", "redis:7-alpine"), ("nextcloud", "nextcloud:stable"),
    ("uptime-kuma", "louislam/uptime-kuma:1"), ("netdata", "netdata/netdata:stable"),
]
MEM = {"jupyter": 380, "nextcloud": 210, "postgres": 90, "code": 160, "netdata": 140, "portainer": 45,
       "uptime-kuma": 95, "redis": 12, "adminer": 18, "dashboard": 24, "socket-proxy": 8}
C = {}
for svc, img in SERVICES:
    cid = hashlib.sha256(svc.encode()).hexdigest()
    C[cid] = {"svc": svc, "img": img, "state": "running", "since": time.time() - random.randint(3600, 400000), "cpu": 0}
C[[k for k, v in C.items() if v["svc"] == "adminer"][0]]["state"] = "exited"
EXTRA_ID = hashlib.sha256(b"other-project").hexdigest()  # container di luar stack: tidak boleh muncul / disentuh


def frame(stream, text):
    b = text.encode()
    return bytes([stream, 0, 0, 0]) + len(b).to_bytes(4, "big") + b


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def out(self, code, body=b"", ctype="application/json"):
        if not isinstance(body, bytes):
            body = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        p = self.path
        if p.startswith("/containers/json"):
            assert "com.docker.compose.project%3Dserverku" in p or "com.docker.compose.project=serverku" in p, p
            res = []
            for cid, c in C.items():
                age = int(time.time() - c["since"])
                st = f"Up {age // 3600} hours" if c["state"] == "running" else "Exited (0) 3 minutes ago"
                if c["svc"] in ("postgres",) and c["state"] == "running": st += " (healthy)"
                res.append({"Id": cid, "Names": [f"/serverku-{c['svc']}-1"], "Image": c["img"], "State": c["state"],
                            "Status": st, "Created": int(c["since"]),
                            "Labels": {"com.docker.compose.project": PROJECT, "com.docker.compose.service": c["svc"]}})
            return self.out(200, res)
        m = re.match(r"^/containers/([a-f0-9]+)/stats", p)
        if m and m.group(1) in C:
            c = C[m.group(1)]
            c["cpu"] += int(random.uniform(0.2, 9 if c["svc"] in ("jupyter", "netdata") else 3) * 1e7)
            sysu = int(time.time() * 1e9) * 4
            mem = MEM.get(c["svc"], 50) * 2**20 * random.uniform(.95, 1.05)
            return self.out(200, {
                "cpu_stats": {"cpu_usage": {"total_usage": c["cpu"]}, "system_cpu_usage": sysu, "online_cpus": 4},
                "precpu_stats": {"cpu_usage": {"total_usage": c["cpu"] - int(random.uniform(.1, 6) * 1e7)}, "system_cpu_usage": sysu - 4 * 10**9},
                "memory_stats": {"usage": int(mem + 20 * 2**20), "limit": 8 * 2**30, "stats": {"inactive_file": 20 * 2**20}}})
        m = re.match(r"^/containers/([a-f0-9]+)/logs", p)
        if m and m.group(1) in C:
            svc = C[m.group(1)]["svc"]
            now = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
            lines = [frame(1, f"{now}.000000000Z [{svc}] layanan siap menerima koneksi\n"),
                     frame(1, f"{now}.100000000Z [{svc}] GET /health 200 3ms\n"),
                     frame(2, f"{now}.200000000Z [{svc}] WARNING: contoh peringatan\n"),
                     frame(2, f"{now}.300000000Z [{svc}] ERROR: contoh error untuk uji pewarnaan\n")]
            return self.out(200, b"".join(lines), "application/vnd.docker.raw-stream")
        if p == "/version":
            return self.out(200, {"Version": "mock"})
        return self.out(404, {"message": "not found"})

    def do_POST(self):
        m = re.match(r"^/containers/([a-f0-9]+)/(start|stop|restart)", self.path)
        if not m or m.group(1) not in C:
            return self.out(404, {"message": "no such container"})
        c = C[m.group(1)]
        if m.group(2) == "start" and c["state"] == "running":
            return self.out(304)
        c["state"] = "exited" if m.group(2) == "stop" else "running"
        if m.group(2) != "stop": c["since"] = time.time()
        return self.out(204)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 2375
    print(f"mock docker di :{port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
