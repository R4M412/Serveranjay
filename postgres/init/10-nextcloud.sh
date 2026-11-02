#!/bin/sh
# Dijalankan otomatis SEKALI saat database pertama kali dibuat.
# Membuat user + database terpisah untuk Nextcloud (prinsip least privilege).
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	CREATE USER nextcloud WITH PASSWORD '${NEXTCLOUD_DB_PASSWORD}';
	CREATE DATABASE nextcloud OWNER nextcloud;
EOSQL
echo "[init] database 'nextcloud' siap."
