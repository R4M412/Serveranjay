#!/usr/bin/env bash
# =====================================================================
#  SERVER PRIBADI — alat harian
#  sudo ./server.sh <perintah>
# =====================================================================
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
[[ -f .env ]] || { echo "Belum terpasang. Jalankan dulu: sudo ./install.sh"; exit 1; }
B=$'\e[1m'; G=$'\e[32m'; D=$'\e[2m'; Y=$'\e[33m'; Z=$'\e[0m'

envget() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | sed "s/^'//;s/'\$//"; }
DC() { docker compose "$@"; }

url() { # url <sub> <port> <scheme>
  if [[ "$(envget MODE)" != "local" ]]; then
    [[ "$1" == "@" ]] && echo "https://$(envget DOMAIN)" || echo "https://$1.$(envget DOMAIN)"
  else
    echo "$3://$(envget HOST_ADDR):$2"
  fi
}

cmd_info() {
  local U; U=$(envget ADMIN_USER)
  local full=0; [[ "$(envget COMPOSE_PROFILES)" == *full* ]] && full=1
  echo "${B}  ┌─ AKSES SERVER ─────────────────────────────────────────────────────${Z}"
  row() { printf "  │ ${B}%-14s${Z} %-38s ${D}%s${Z}\n" "$1" "$2" "$3"; }
  row "Pusat Kendali" "$(url @ 8000 http)"        "user: $U  pass: $(envget ADMIN_PASSWORD)"
  row "Portainer"     "$(url portainer 9443 https)" "user: admin  pass: $(envget PORTAINER_PASSWORD)"
  row "VS Code"       "$(url code 8080 http)"      "pass: $(envget CODE_PASSWORD)"
  [[ $full -eq 1 ]] && row "JupyterLab" "$(url jupyter 8888 http)" "token: $(envget JUPYTER_TOKEN)"
  [[ $full -eq 1 ]] && row "Nextcloud"  "$(url cloud 8081 http)"   "user: $U  pass: $(envget NEXTCLOUD_ADMIN_PASSWORD)"
  row "Adminer (DB)"  "$(url db 8082 http)"        "server: postgres  user: $(envget DB_USER)  pass: $(envget DB_PASSWORD)"
  row "Uptime Kuma"   "$(url status 3001 http)"    "buat akun admin saat pertama dibuka"
  if [[ "$(envget MODE)" == "tunnel" ]]; then
    row "Netdata"     "$(url monitor 19999 http)"  "dilindungi Cloudflare Access"
  elif [[ "$(envget MODE)" == "domain" ]]; then
    row "Netdata"     "$(url monitor 19999 http)"  "user: $U  pass: $(envget NETDATA_PASSWORD)"
  else
    row "Netdata"     "$(url monitor 19999 http)"  "tanpa login — jangan buka ke internet"
    row "PostgreSQL"  "127.0.0.1:5432"             "db: app  user: $(envget DB_USER)  pass: $(envget DB_PASSWORD)"
  fi
  echo "${B}  └────────────────────────────────────────────────────────────────────${Z}"
  [[ "$(envget MODE)" == "local" ]] && echo "  ${D}Portainer memakai sertifikat self-signed: klik 'Advanced → Proceed' di browser.${Z}"
  [[ "$(envget MODE)" == "tunnel" ]] && echo "  ${Y}Semua alamat di atas hanya bisa dibuka setelah lolos Cloudflare Access (kode OTP ke email kamu).${Z}"
  echo "  ${D}Semua password tersimpan di .env (chmod 600). Simpan juga di password manager.${Z}"
}

cmd_backup() {
  local ts dir proj
  ts=$(date +%Y%m%d-%H%M%S); dir="backups/$ts"; proj=$(envget PROJECT_NAME)
  mkdir -p "$dir"; chmod 700 backups
  echo "${B}==> Backup ke $dir${Z}"
  DC exec -T postgres pg_dumpall -U "$(envget DB_USER)" | gzip > "$dir/postgres.sql.gz" && echo "  ${G}✓${Z} database (pg_dumpall)"
  for v in $(docker volume ls -q --filter "label=com.docker.compose.project=$proj"); do
    [[ "$v" == *_pg || "$v" == *netdatacache* || "$v" == *_redis ]] && continue  # DB sudah di-dump; cache dilewati
    docker run --rm -v "$v":/v:ro -v "$PWD/$dir":/b alpine tar czf "/b/$v.tgz" -C /v . 2>/dev/null && echo "  ${G}✓${Z} volume $v"
  done
  cp .env "$dir/env.backup" && chmod 600 "$dir/env.backup"
  echo "  ${G}✓${Z} konfigurasi (.env)"
  ls -1dt backups/*/ 2>/dev/null | tail -n +8 | xargs -r rm -rf   # simpan 7 backup terakhir
  echo "  Ukuran: $(du -sh "$dir" | cut -f1).  ${Y}Salin folder backups/ ke tempat lain (HDD eksternal / cloud).${Z}"
}

cmd_tunnel() {
  local d; d=$(envget DOMAIN)
  echo "${B}  Isi di Cloudflare Zero Trust → Networks → Tunnels → (tunnel kamu) → Public Hostname:${Z}"
  printf "  ${B}%-26s${Z} %s\n" "Hostname" "Service"
  printf "  %-26s %s\n" "$d" "http://dashboard:8000" "panel.$d" "http://dashboard:8000" \
    "portainer.$d" "http://portainer:9000" "code.$d" "http://code:8080" "jupyter.$d" "http://jupyter:8888" \
    "cloud.$d" "http://nextcloud:80" "db.$d" "http://adminer:8080" "status.$d" "http://uptime-kuma:3001" \
    "monitor.$d" "http://netdata:19999"
  echo "  ${Y}Lalu kunci: Zero Trust → Access → Applications → Self-hosted → domain $d dan *.$d → policy Allow → Emails: email kamu.${Z}"
}

cmd_full() {
  case "${1:-}" in
    on)  sed -i 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=full/' .env; DC up -d; echo "JupyterLab + Nextcloud aktif." ;;
    off) DC stop jupyter nextcloud redis 2>/dev/null || true
         sed -i 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=core/' .env; echo "JupyterLab + Nextcloud dimatikan (data tetap aman)." ;;
    *)   echo "Pakai: ./server.sh full on|off   (sekarang: $(envget COMPOSE_PROFILES))" ;;
  esac
}

case "${1:-help}" in
  start)   DC up -d --build ;;
  stop)    DC stop ;;
  restart) DC restart ${2:-} ;;
  status)  DC ps --format "table {{.Service}}\t{{.State}}\t{{.Status}}" ;;
  logs)    DC logs -f --tail=200 ${2:-} ;;
  info)    cmd_info ;;
  backup)  cmd_backup ;;
  update)  DC pull --ignore-buildable 2>/dev/null || DC pull; DC up -d --build --remove-orphans; docker image prune -f >/dev/null; echo "Diperbarui." ;;
  full)    cmd_full "${2:-}" ;;
  tunnel)  cmd_tunnel ;;
  *) cat <<EOF
${B}Server Pribadi — perintah:${Z}
  start            nyalakan semua layanan
  stop             matikan semua layanan (data aman)
  restart [svc]    restart semua / satu layanan
  status           lihat status
  logs [svc]       ikuti log (Ctrl+C keluar)
  info             alamat + username + password semua layanan
  backup           cadangkan database + semua volume ke ./backups
  update           perbarui semua image ke versi terbaru
  full on|off      nyalakan/matikan JupyterLab + Nextcloud (hemat RAM)
  tunnel           daftar hostname yang harus diisi di Cloudflare Tunnel
EOF
  ;;
esac
