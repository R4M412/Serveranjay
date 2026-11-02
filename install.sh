#!/usr/bin/env bash
# =====================================================================
#  SERVER PRIBADI — instalasi sekali jalan
#  Pakai:  sudo ./install.sh
#  Tanpa tanya-tanya:
#    sudo MODE=local ./install.sh --yes
#    sudo MODE=domain DOMAIN=contoh.com ACME_EMAIL=saya@contoh.com ./install.sh --yes
#    sudo MODE=tunnel DOMAIN=contoh.com CF_TUNNEL_TOKEN=eyJ... ./install.sh --yes
# =====================================================================
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

C_OK=$'\e[32m'; C_W=$'\e[33m'; C_E=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'
say()  { echo "${C_B}==>${C_0} $*"; }
ok()   { echo "${C_OK}  ✓${C_0} $*"; }
warn() { echo "${C_W}  !${C_0} $*"; }
die()  { echo "${C_E}  ✗ $*${C_0}" >&2; exit 1; }

YES=0; [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && YES=1
ask() { # ask "Pertanyaan" default -> echo jawaban
  local q="$1" d="${2:-}" a
  if [[ $YES -eq 1 ]]; then echo "$d"; return; fi
  read -r -p "  $q${d:+ [$d]}: " a </dev/tty || true
  echo "${a:-$d}"
}
gen() { # password acak alfanumerik (aman untuk YAML, SQL, URL)
  local n="${1:-24}" out=""
  while [[ ${#out} -lt $n ]]; do
    out+=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' || true)
  done
  echo "${out:0:$n}"
}

echo
echo "${C_B}  ┌──────────────────────────────────────────┐"
echo "  │      SERVER PRIBADI · instalasi            │"
echo "  └──────────────────────────────────────────┘${C_0}"
echo

# ---------------------------------------------------------------- 1. prasyarat
say "1/6 Memeriksa sistem"
[[ "$(uname -s)" == "Linux" ]] || die "Butuh Linux (Ubuntu/Debian disarankan). Di Windows pakai WSL2 + Docker Desktop."
[[ $EUID -eq 0 ]] || die "Jalankan dengan sudo:  sudo ./install.sh"
ARCH=$(uname -m); ok "Linux $ARCH"
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
DISK_GB=$(df -Pk . | awk 'NR==2{print int($4/1024/1024)}')
ok "RAM ${MEM_MB} MB, disk kosong ${DISK_GB} GB"
[[ $DISK_GB -lt 15 ]] && warn "Disk kosong < 15 GB — semua image butuh ±6 GB, sisakan ruang untuk data."
for bin in curl awk; do command -v $bin >/dev/null || die "Perintah '$bin' tidak ada. Pasang dulu: apt install $bin"; done

# ---------------------------------------------------------------- 2. docker
say "2/6 Memeriksa Docker"
if ! command -v docker >/dev/null; then
  warn "Docker belum terpasang — memasang lewat skrip resmi get.docker.com"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker 2>/dev/null || true
fi
docker info >/dev/null 2>&1 || die "Docker terpasang tapi daemon tidak jalan. Coba: systemctl start docker"
docker compose version >/dev/null 2>&1 || die "Plugin 'docker compose' tidak ada. Pasang: apt install docker-compose-plugin"
ok "$(docker --version)"
ok "$(docker compose version)"
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && ! id -nG "$SUDO_USER" | grep -qw docker; then
  usermod -aG docker "$SUDO_USER" && ok "User '$SUDO_USER' ditambahkan ke grup docker (berlaku setelah login ulang)"
fi

# ---------------------------------------------------------------- 3. konfigurasi
say "3/6 Konfigurasi"
if [[ -f .env ]]; then
  ok ".env sudah ada — memakai konfigurasi & password lama (tidak dibuat ulang)"
else
  DEFAULT_IP=$(hostname -I 2>/dev/null | awk '{print $1}'); DEFAULT_IP=${DEFAULT_IP:-127.0.0.1}
  if [[ -z "${MODE:-}" ]]; then
    echo "  Pilih mode:"
    echo "    1) local  — tanpa domain, akses via IP:PORT (PC rumah / LAN)"
    echo "    2) domain — VPS + domain, semua lewat HTTPS otomatis"
    echo "    3) tunnel — Cloudflare Tunnel: link internet + dikunci email kamu, tanpa buka port"
    m=$(ask "Pilihan" 1)
    case "$m" in 2|domain) MODE=domain ;; 3|tunnel) MODE=tunnel ;; *) MODE=local ;; esac
  fi
  [[ "$MODE" =~ ^(local|domain|tunnel)$ ]] || die "MODE harus 'local', 'domain', atau 'tunnel'"
  CF_TUNNEL_TOKEN=${CF_TUNNEL_TOKEN:-}

  if [[ "$MODE" == "tunnel" ]]; then
    DOMAIN=${DOMAIN:-$(ask "Domain di Cloudflare (contoh: serverku.my.id)" "")}
    [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "Domain tidak valid: '$DOMAIN'"
    [[ -n "$CF_TUNNEL_TOKEN" ]] || { [[ $YES -eq 1 ]] && die "CF_TUNNEL_TOKEN wajib diisi"; read -r -s -p "  Token tunnel Cloudflare (tidak ditampilkan): " CF_TUNNEL_TOKEN </dev/tty; echo; }
    [[ ${#CF_TUNNEL_TOKEN} -gt 50 ]] || die "Token terlalu pendek — salin seluruh teks setelah '--token' dari dashboard Cloudflare"
    ACME_EMAIL=none@local.invalid
    HOST_ADDR=$DOMAIN
    COMPOSE_FILE="docker-compose.yml:compose.tunnel.yml"
    BIND_IP=127.0.0.1
  elif [[ "$MODE" == "domain" ]]; then
    DOMAIN=${DOMAIN:-$(ask "Domain (contoh: serverku.com)" "")}
    [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "Domain tidak valid: '$DOMAIN'"
    ACME_EMAIL=${ACME_EMAIL:-$(ask "Email untuk sertifikat Let's Encrypt" "admin@$DOMAIN")}
    HOST_ADDR=${HOST_ADDR:-$DOMAIN}
    COMPOSE_FILE="docker-compose.yml:compose.domain.yml"
    BIND_IP=127.0.0.1
  else
    DOMAIN=${DOMAIN:-local.invalid}
    ACME_EMAIL=${ACME_EMAIL:-none@local.invalid}
    HOST_ADDR=${HOST_ADDR:-$(ask "Alamat IP server ini" "$DEFAULT_IP")}
    BIND_IP=${BIND_IP:-$(ask "Buka ke jaringan? 0.0.0.0 = ya (LAN), 127.0.0.1 = hanya mesin ini" "0.0.0.0")}
    COMPOSE_FILE="docker-compose.yml:compose.local.yml"
  fi

  ADMIN_USER=${ADMIN_USER:-$(ask "Username admin" "admin")}
  [[ "$ADMIN_USER" =~ ^[a-z][a-z0-9_]{2,31}$ ]] || die "Username: huruf kecil/angka/_, 3–32 karakter, diawali huruf"

  if [[ -z "${PROFILES:-}" ]]; then
    if [[ $MEM_MB -ge 3500 ]]; then PROFILES=full
    else
      warn "RAM < 3.5 GB: JupyterLab & Nextcloud dimatikan dulu (profil 'core')."
      warn "Aktifkan nanti dengan:  sudo ./server.sh full on"
      PROFILES=core
    fi
  fi

  ADMIN_PASSWORD=$(gen 20)
  NETDATA_PW=$(gen 20)
  command -v openssl >/dev/null || { apt-get install -y openssl >/dev/null 2>&1 || true; }
  NETDATA_HASH=$(openssl passwd -apr1 "$NETDATA_PW")

  umask 077
  cat > .env <<EOF
# ===== dibuat oleh install.sh pada $(date '+%Y-%m-%d %H:%M') — RAHASIA, jangan dibagikan =====
PROJECT_NAME=serverku
MODE=$MODE
COMPOSE_FILE=$COMPOSE_FILE
COMPOSE_PROFILES=$PROFILES
DOMAIN=$DOMAIN
ACME_EMAIL=$ACME_EMAIL
HOST_ADDR=$HOST_ADDR
BIND_IP=$BIND_IP
TZ=Asia/Jakarta

ADMIN_USER=$ADMIN_USER
ADMIN_PASSWORD=$ADMIN_PASSWORD
CODE_PASSWORD=$(gen 20)
JUPYTER_TOKEN=$(gen 32)
DB_USER=$ADMIN_USER
DB_PASSWORD=$(gen 24)
NEXTCLOUD_DB_PASSWORD=$(gen 24)
NEXTCLOUD_ADMIN_PASSWORD=$(gen 20)
REDIS_PASSWORD=$(gen 24)
PORTAINER_PASSWORD=$(gen 20)
NETDATA_PASSWORD=$NETDATA_PW
NETDATA_BASIC_AUTH='$ADMIN_USER:$NETDATA_HASH'
CF_TUNNEL_TOKEN=$CF_TUNNEL_TOKEN
EOF
  chmod 600 .env
  ok ".env dibuat (chmod 600) — semua password acak & unik"
fi

# ---------------------------------------------------------------- 4. file rahasia
say "4/6 Menyiapkan secrets"
set -a; # shellcheck disable=SC1090
source <(grep -E '^[A-Z_]+=' .env | grep -v '^NETDATA_BASIC_AUTH='); set +a
mkdir -p secrets backups; chmod 700 secrets
printf '%s' "$PORTAINER_PASSWORD" > secrets/portainer_admin_password
chmod 644 secrets/portainer_admin_password   # dibaca container; folder induk tetap 700
chmod +x postgres/init/*.sh server.sh 2>/dev/null || true
ok "secrets/portainer_admin_password"

# ---------------------------------------------------------------- 5. firewall
say "5/6 Firewall"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null
  if [[ "$MODE" == "tunnel" ]]; then
    ok "ufw: mode tunnel tidak butuh port masuk apa pun (hanya SSH)"
  elif [[ "$MODE" == "domain" ]]; then
    ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
    ok "ufw: 22, 80, 443 dibuka"
  else
    for p in 8000 9443 8080 8888 8081 8082 3001 19999; do ufw allow from 10.0.0.0/8 to any port $p proto tcp >/dev/null; ufw allow from 172.16.0.0/12 to any port $p proto tcp >/dev/null; ufw allow from 192.168.0.0/16 to any port $p proto tcp >/dev/null; done
    ok "ufw: port layanan dibuka HANYA untuk jaringan lokal (LAN)"
  fi
  warn "Catatan: port yang dipublikasikan Docker bisa melewati ufw — karena itu tiap layanan tetap wajib login."
else
  warn "ufw tidak aktif — dilewati. Di VPS disarankan: ufw allow OpenSSH && ufw allow 80,443/tcp && ufw enable"
fi

# ---------------------------------------------------------------- 6. nyalakan
say "6/6 Mengunduh image & menyalakan layanan (pertama kali bisa 5–15 menit)"
docker compose pull --ignore-buildable 2>/dev/null || docker compose pull --ignore-pull-failures || true
docker compose up -d --build --remove-orphans
ok "Semua layanan dijalankan"
echo
./server.sh info
echo
if [[ "$(grep -E '^MODE=' .env | cut -d= -f2)" == "tunnel" ]]; then
  ./server.sh tunnel
  echo
fi
if [[ "$MODE" == "domain" ]]; then
  warn "Pastikan DNS:  A $DOMAIN -> IP server   dan   A *.$DOMAIN -> IP server"
  warn "Sertifikat HTTPS dibuat otomatis saat alamat pertama kali dibuka (±1 menit)."
fi
warn "Uptime Kuma: buat akun admin-nya SEGERA di halaman pertama kali dibuka."
warn "Nextcloud butuh 1–3 menit untuk instalasi awal sebelum bisa dibuka."
echo "${C_OK}${C_B}  Selesai. Selamat datang di server milikmu sendiri.${C_0}"
