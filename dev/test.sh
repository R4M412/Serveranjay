#!/usr/bin/env bash
# Uji Pusat Kendali tanpa Docker: jalankan mock Docker API + dashboard, lalu tes API-nya.
#   bash dev/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
PW="uji-coba-password-123"
python3 dev/mock_docker.py 23750 & M=$!
ADMIN_USER=admin ADMIN_PASSWORD="$PW" DOCKER_HOST=tcp://127.0.0.1:23750 HOST_PROC=/proc \
  HOST_ADDR=192.168.1.10 PORT=18000 REFRESH_SEC=1 python3 dashboard/app.py > /tmp/pk.log 2>&1 & D=$!
trap 'kill $M $D 2>/dev/null' EXIT
sleep 2.5
B=http://127.0.0.1:18000; H="X-Requested-With: pusat-kendali"; J="/tmp/pk.cookies"; rm -f $J
pass=0; fail=0
t() { if eval "$2"; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1"; fail=$((fail+1)); fi; }

t "healthz"                        '[[ $(curl -s $B/healthz) == *true* ]]'
t "halaman utama tersaji"          '[[ $(curl -s $B/) == *"Pusat Kendali"* ]]'
t "API terkunci tanpa login (401)" '[[ $(curl -s -o /dev/null -w "%{http_code}" $B/api/overview) == 401 ]]'
t "POST tanpa header CSRF ditolak" '[[ $(curl -s -o /dev/null -w "%{http_code}" -X POST $B/api/login -d "{}") == 403 ]]'
t "password salah ditolak (401)"   '[[ $(curl -s -o /dev/null -w "%{http_code}" -X POST -H "$H" $B/api/login -d "{\"username\":\"admin\",\"password\":\"x\"}") == 401 ]]'
t "login benar -> cookie HttpOnly" '[[ $(curl -s -i -c $J -X POST -H "$H" $B/api/login -d "{\"username\":\"admin\",\"password\":\"'$PW'\"}") == *"HttpOnly; SameSite=Strict"* ]]'
O=$(curl -s -b $J $B/api/overview)
t "overview: docker terhubung"     '[[ $(echo "$O" | python3 -c "import json,sys;print(json.load(sys.stdin)[\"docker_ok\"])") == True ]]'
t "overview: 11 layanan terbaca"   '[[ $(echo "$O" | python3 -c "import json,sys;print(len(json.load(sys.stdin)[\"services\"]))") == 11 ]]'
t "overview: statistik host (RAM)" '[[ $(echo "$O" | python3 -c "import json,sys;print(json.load(sys.stdin)[\"host\"][\"memory\"][\"total\"]>0)") == True ]]'
t "overview: CPU/RAM per container" '[[ $(echo "$O" | python3 -c "import json,sys;d=json.load(sys.stdin);print(all(s[\"stats\"] for s in d[\"services\"] if s[\"state\"]==\"running\"))") == True ]]'
sid() { echo "$O" | python3 -c "import json,sys;print([s[\"id\"] for s in json.load(sys.stdin)[\"services\"] if s[\"service\"]==\"$1\"][0])"; }
CODE=$(sid code); ADM=$(sid adminer); DASH=$(sid dashboard)
t "log: demux frame Docker"        '[[ $(curl -s -b $J $B/api/services/$CODE/logs?tail=50) == *"layanan siap"* ]]'
t "stop code-server"               '[[ $(curl -s -b $J -X POST -H "$H" $B/api/services/$CODE/stop) == *true* ]]'
t "start adminer (tadinya mati)"   '[[ $(curl -s -b $J -X POST -H "$H" $B/api/services/$ADM/start) == *true* ]]'
t "restart code-server"            '[[ $(curl -s -b $J -X POST -H "$H" $B/api/services/$CODE/restart) == *true* ]]'
t "dashboard dilindungi dari stop" '[[ $(curl -s -o /dev/null -w "%{http_code}" -b $J -X POST -H "$H" $B/api/services/$DASH/stop) == 400 ]]'
t "container luar stack ditolak"   '[[ $(curl -s -o /dev/null -w "%{http_code}" -b $J -X POST -H "$H" $B/api/services/abcdefabcdef/stop) == 404 ]]'
t "path traversal static ditolak"  '[[ $(curl -s -o /dev/null -w "%{http_code}" --path-as-is $B/static/../app.py) == 404 ]]'
curl -s -b $J -X POST -H "$H" $B/api/logout >/dev/null
t "logout mencabut sesi"           '[[ $(curl -s -o /dev/null -w "%{http_code}" -b $J $B/api/overview) == 401 ]]'
for i in 1 2 3 4 5; do curl -s -o /dev/null -X POST -H "$H" $B/api/login -d '{"username":"a","password":"b"}'; done
t "brute force dikunci (429)"      '[[ $(curl -s -o /dev/null -w "%{http_code}" -X POST -H "$H" $B/api/login -d "{\"username\":\"admin\",\"password\":\"'$PW'\"}") == 429 ]]'
echo; echo "  Hasil: $pass lulus, $fail gagal"; [[ $fail -eq 0 ]]
