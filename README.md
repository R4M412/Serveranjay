# 🖥️ Server Pribadi

Paket siap pasang untuk membangun **server milikmu sendiri**: 10 layanan, satu panel kendali, satu perintah instalasi.
Bisa dipasang di PC/laptop bekas, mini PC, Raspberry Pi 4/5 (64-bit), atau VPS.

```
                         ┌──────────────── Internet / LAN ────────────────┐
                         │                                                 │
                 (mode domain)  Traefik :443  ── HTTPS otomatis ──┐   (mode local)  IP:PORT
                                                                  ▼
 ┌───────────────┬───────────────┬──────────────┬──────────────┬──────────────┬──────────────┐
 │ Pusat Kendali │  Portainer    │  VS Code     │  JupyterLab  │  Nextcloud   │  Uptime Kuma │
 │ (panel ini)   │  (container)  │  (coding)    │  (Python)    │  (cloud)     │  (pemantau)  │
 └──────┬────────┴───────────────┴──────┬───────┴──────┬───────┴──────┬───────┴──────────────┘
        │ hanya baca + start/stop       │              │              │        Netdata (monitor)
        ▼                               ▼              ▼              ▼
  Docker Socket Proxy             PostgreSQL 16  ◄── Adminer      Redis (cache)
```

## Isi paket

| Layanan | Fungsi | Mode local | Mode domain |
|---|---|---|---|
| **Pusat Kendali** | Panel buatan sendiri: CPU/RAM/disk, status semua layanan, start/stop/restart, lihat log | `:8000` | `namadomain.com` |
| **Portainer** | Kelola container, image, volume, network | `:9443` (https) | `portainer.` |
| **VS Code** (code-server) | Coding di browser dari perangkat apa pun | `:8080` | `code.` |
| **JupyterLab** | Notebook Python, numpy, pandas, matplotlib | `:8888` | `jupyter.` |
| **Nextcloud** | Cloud storage pribadi (sinkron HP/laptop) | `:8081` | `cloud.` |
| **Adminer** | Kelola database lewat web | `:8082` | `db.` |
| **PostgreSQL 16** | Database utama untuk aplikasimu | `127.0.0.1:5432` | internal |
| **Uptime Kuma** | Pantau website/layanan + notifikasi Telegram/Discord/email | `:3001` | `status.` |
| **Netdata** | Grafik detail real-time sampai level proses | `:19999` | `monitor.` (pakai login) |
| **Traefik** | Reverse proxy + sertifikat Let's Encrypt otomatis | – | `:80/:443` |
| **Cloudflare Tunnel** | Link internet tanpa buka port, dikunci email (mode tunnel) | – | – |

## Kebutuhan

- Linux 64-bit (Ubuntu 22.04/24.04 atau Debian 12 disarankan), akses `sudo`
- RAM **4 GB+** untuk semua layanan (2 GB bisa, tapi JupyterLab + Nextcloud otomatis dimatikan dulu)
- Disk kosong **20 GB+**
- Mode domain: domain + DNS `A @` dan `A *` diarahkan ke IP server, port 80/443 terbuka

## Instalasi (3 langkah)

```bash
# 1. salin folder ini ke server, lalu masuk
cd server-pribadi

# 2. pasang (Docker dipasang otomatis kalau belum ada)
sudo bash install.sh

# 3. lihat alamat + password semua layanan
sudo ./server.sh info
```

Installer akan bertanya: mode (local/domain), IP atau domain, dan username admin.
**Semua password dibuat acak dan unik di mesinmu sendiri**, disimpan di `.env` (chmod 600), tidak pernah dikirim ke mana pun.

Tanpa tanya-jawab:
```bash
sudo MODE=local ./install.sh --yes
sudo MODE=domain DOMAIN=serverku.com ACME_EMAIL=saya@serverku.com ./install.sh --yes
sudo MODE=tunnel DOMAIN=serverku.my.id CF_TUNNEL_TOKEN=eyJ... ./install.sh --yes
```

## 🔒 Mode Tunnel — link internet yang dikunci khusus untukmu (Cloudflare)

Cocok untuk server di rumah: **tidak perlu IP publik, tidak perlu port-forward router, tidak ada port yang dibuka.**
Server yang menyambung keluar ke Cloudflare, lalu setiap orang yang membuka link harus lolos **Cloudflare Access**
(kode OTP dikirim ke email kamu). Orang lain hanya melihat halaman login Cloudflare. Gratis untuk ≤50 pengguna.

**Yang dibutuhkan:** akun Cloudflare gratis + 1 domain yang DNS-nya dipindah ke Cloudflare
(domain `.my.id` sekitar Rp10–20 ribu/tahun di registrar Indonesia, atau beli langsung di Cloudflare Registrar).

1. **Buat tunnel** — dash.cloudflare.com → *Zero Trust* → *Networks* → *Tunnels* → *Create a tunnel* → *Cloudflared* → beri nama → di langkah instalasi, salin **token** (teks panjang setelah `--token`, diawali `eyJ`). Tidak perlu menjalankan perintah instalasi dari Cloudflare.
2. **Pasang server** — `sudo bash install.sh` → pilih **3) tunnel** → isi domain + tempel token.
3. **Daftarkan hostname** — jalankan `sudo ./server.sh tunnel`, lalu masukkan setiap baris ke tab *Public Hostname* tunnel kamu (contoh: `code.serverku.my.id` → `http://code:8080`).
4. **Kunci untuk kamu saja** — *Zero Trust* → *Access* → *Applications* → *Add an application* → *Self-hosted*:
   - Application domain: `serverku.my.id` **dan** `*.serverku.my.id`
   - Policy: **Allow** → Include → **Emails** → email kamu
   - Login method: **One-time PIN**
5. Buka `https://serverku.my.id` → masukkan email → kode OTP → login Pusat Kendali.

Dua lapis kunci: Cloudflare Access (email kamu) **lalu** password masing-masing layanan.

## Pemakaian harian

```bash
sudo ./server.sh status         # status semua layanan
sudo ./server.sh info           # alamat + username + password
sudo ./server.sh logs nextcloud # ikuti log satu layanan
sudo ./server.sh restart code   # restart satu layanan
sudo ./server.sh backup         # backup DB + semua data ke ./backups (simpan 7 terakhir)
sudo ./server.sh update         # perbarui semua layanan ke versi terbaru
sudo ./server.sh full off       # matikan Jupyter + Nextcloud untuk hemat RAM
sudo ./server.sh tunnel         # daftar hostname untuk Cloudflare Tunnel
sudo ./server.sh stop           # matikan semua (data tetap aman)
```

Backup otomatis tiap jam 2 pagi:
```bash
echo "0 2 * * * root cd $(pwd) && ./server.sh backup >> backups/cron.log 2>&1" | sudo tee /etc/cron.d/server-pribadi
```

## Keamanan yang sudah dipasang

- Password acak 20–32 karakter, beda untuk setiap layanan; Portainer langsung terkunci dengan password (tidak bisa "direbut" saat pertama dibuka)
- Pusat Kendali **tidak** memegang docker.sock: lewat **socket-proxy** yang hanya mengizinkan baca + start/stop/restart (tidak bisa membuat container atau exec)
- Panel memakai sesi HttpOnly + SameSite=Strict, perlindungan CSRF, dan kunci 10 menit setelah 5 kali salah login
- Panel inti (dashboard, socket-proxy, traefik) tidak bisa dimatikan dari panel itu sendiri
- Database tidak pernah dibuka ke jaringan (hanya `127.0.0.1`)
- Nextcloud memakai user database terpisah (bukan superuser)
- Log tiap container dibatasi 30 MB agar disk tidak penuh
- Mode domain: semua lewat HTTPS, HTTP otomatis dialihkan, Netdata dilindungi basic-auth

**Wajib kamu lakukan:**
1. Buka **Uptime Kuma** segera setelah instalasi dan buat akun admin (dia meminta akun saat pertama dibuka).
2. Mode local dengan `BIND_IP=0.0.0.0`: **jangan** port-forward router ke port-port ini. Untuk akses dari luar rumah pakai **Tailscale** (gratis): `curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up`
3. Salin isi `backups/` ke tempat lain secara rutin.
4. Simpan isi `.env` di password manager.

## Struktur

```
server-pribadi/
├── install.sh              # instalasi sekali jalan
├── server.sh               # alat harian (status, info, backup, update…)
├── docker-compose.yml      # definisi semua layanan
├── compose.local.yml       # tambahan untuk mode local (port)
├── compose.domain.yml      # tambahan untuk mode domain (Traefik + HTTPS)
├── compose.tunnel.yml      # tambahan untuk mode tunnel (Cloudflare)
├── postgres/init/          # skrip pembuatan database Nextcloud
├── dashboard/              # Pusat Kendali (Python stdlib + HTML/CSS/JS, tanpa dependensi)
└── dev/                    # mock Docker API + 19 uji otomatis panel (bash dev/test.sh)
```

## Mengatasi masalah

| Gejala | Solusi |
|---|---|
| Nextcloud "Access through untrusted domain" | `sudo docker compose exec -u www-data nextcloud php occ config:system:set trusted_domains 5 --value=ALAMAT_BARU` |
| Portainer: peringatan sertifikat | Normal di mode local (self-signed). Klik *Advanced → Proceed*. |
| HTTPS gagal (mode domain) | Cek DNS sudah mengarah ke IP server & port 80 terbuka: `sudo ./server.sh logs traefik` |
| Link tunnel "Bad gateway" / 502 | Layanan belum siap atau hostname salah ketik. Cek `sudo ./server.sh status` dan `sudo ./server.sh logs cloudflared` |
| RAM penuh | `sudo ./server.sh full off` lalu cek panel |
| Ganti IP server (mode local) | Edit `HOST_ADDR` di `.env`, lalu `sudo ./server.sh start` |
| Mulai dari nol (HAPUS SEMUA DATA) | `sudo docker compose down -v && rm .env` lalu `sudo ./install.sh` |

## Menambah aplikasimu sendiri

Tambahkan service baru di `docker-compose.yml`, beri label Traefik seperti layanan lain, lalu `sudo ./server.sh start`.
Aplikasi otomatis muncul di Pusat Kendali karena memakai proyek compose yang sama.
Untuk database: hubungkan ke host `postgres` port `5432` dari network `db`.
