#!/usr/bin/env bash
# Target MongoDB setup - accounts + empty databases (shop_empty_db, hr_empty_db) only
set -euo pipefail

echo "[DB-Target/MongoDB] Starting setup..."

# ── Wait for MongoDB ──────────────────────────────────────────────────────────
MAX_RETRY=30
RETRY=0
until mongosh --quiet --eval "db.adminCommand('ping').ok" 2>/dev/null | grep -q "1"; do
    RETRY=$((RETRY + 1))
    if [[ $RETRY -ge $MAX_RETRY ]]; then
        echo "[DB-Target/MongoDB] ERROR: MongoDB did not start within timeout."
        exit 1
    fi
    echo "[DB-Target/MongoDB] Waiting for MongoDB... (${RETRY}/${MAX_RETRY})"
    sleep 2
done
echo "[DB-Target/MongoDB] MongoDB ready."

# ── Create accounts (the first one needs no auth, via the localhost exception) ───
mongosh admin --quiet --eval '
db.createUser({
    user: "root",
    pwd: "testpass123",
    roles: [ { role: "root", db: "admin" } ]
});
'

# Migration destination account (created while authenticated as root)
mongosh admin -u root -p testpass123 --authenticationDatabase admin --quiet --eval '
db.createUser({
    user: "centipede",
    pwd: "centipede_pass",
    roles: [ { role: "root", db: "admin" } ]
});

// When dstConnection sets db_name the URI becomes mongodb://.../<db>, and that DB is
// treated as the authSource. Create the centipede account inside each target DB up front,
// before any data exists. Target DB names differ from the source ones, so
// dstConnection.db_name must name shop_empty_db / hr_empty_db explicitly.
db.getSiblingDB("shop_empty_db").createUser({
    user: "centipede",
    pwd: "centipede_pass",
    roles: [ { role: "readWrite", db: "shop_empty_db" } ]
});
db.getSiblingDB("hr_empty_db").createUser({
    user: "centipede",
    pwd: "centipede_pass",
    roles: [ { role: "readWrite", db: "hr_empty_db" } ]
});

// In MongoDB a database with no collections does not really exist and never shows up
// in show dbs, so create one placeholder collection each to make the empty DBs exist.
db.getSiblingDB("shop_empty_db").createCollection("_centipede_placeholder");
db.getSiblingDB("hr_empty_db").createCollection("_centipede_placeholder");
'

echo "[DB-Target/MongoDB] Credentials configured; empty databases (shop_empty_db, hr_empty_db) created. Ready to receive migration."
