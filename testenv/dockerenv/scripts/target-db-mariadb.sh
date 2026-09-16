#!/usr/bin/env bash
# Target MariaDB setup - accounts + empty databases (shop_empty_db, hr_empty_db) only
set -euo pipefail

echo "[DB-Target/MariaDB] Starting setup..."

# ── Wait for MariaDB ──────────────────────────────────────────────────────────
MAX_RETRY=30
RETRY=0
until mysqladmin ping --silent 2>/dev/null; do
    RETRY=$((RETRY + 1))
    if [[ $RETRY -ge $MAX_RETRY ]]; then
        echo "[DB-Target/MariaDB] ERROR: MariaDB did not start within timeout."
        exit 1
    fi
    echo "[DB-Target/MariaDB] Waiting for MariaDB... (${RETRY}/${MAX_RETRY})"
    sleep 2
done
echo "[DB-Target/MariaDB] MariaDB ready."

# ── Set the root password + accounts + create empty databases ─────────────────
mysql --default-character-set=utf8mb4 -u root <<'SQL'
ALTER USER 'root'@'localhost' IDENTIFIED BY 'testpass123';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');

-- Migration destination account (may create and write to any database)
CREATE USER IF NOT EXISTS 'centipede'@'%' IDENTIFIED BY 'centipede_pass';
GRANT ALL PRIVILEGES ON *.* TO 'centipede'@'%' WITH GRANT OPTION;

-- Pre-create empty databases on the target (no tables or rows, migration destination)
CREATE DATABASE IF NOT EXISTS shop_empty_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS hr_empty_db   CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

FLUSH PRIVILEGES;
SQL

echo "[DB-Target/MariaDB] Credentials configured; empty databases (shop_empty_db, hr_empty_db) created. Ready to receive migration."
