#!/bin/bash
set -euo pipefail

OLD_DATA_DIR="/var/lib/postgresql/9.6/main"
NEW_DATA_DIR="/var/lib/postgresql/16/main"
OLD_BIN="/usr/lib/postgresql/9.6/bin"
NEW_BIN="/usr/lib/postgresql/16/bin"
WORK_DIR="/var/lib/postgresql"

# pg_upgrade writes log files and post-upgrade scripts (analyze_new_cluster.sh,
# delete_old_cluster.sh) to the current working directory, which must be
# writable by the postgres user.
cd "${WORK_DIR}"

echo "==> Initializing PostgreSQL 16 cluster at ${NEW_DATA_DIR}"
"${NEW_BIN}/initdb" \
  -D "${NEW_DATA_DIR}" \
  --encoding=UTF8 \
  --locale=en_US.UTF-8

echo "==> Running pg_upgrade compatibility check (dry run)"
"${NEW_BIN}/pg_upgrade" \
  -b "${OLD_BIN}" \
  -B "${NEW_BIN}" \
  -d "${OLD_DATA_DIR}" \
  -D "${NEW_DATA_DIR}" \
  --check

echo "==> Compatibility check passed. Running pg_upgrade"
"${NEW_BIN}/pg_upgrade" \
  -b "${OLD_BIN}" \
  -B "${NEW_BIN}" \
  -d "${OLD_DATA_DIR}" \
  -D "${NEW_DATA_DIR}"

echo "==> Running post-upgrade ANALYZE on all databases"
if [ -f ./analyze_new_cluster.sh ]; then
  # pg_upgrade writes this script to the current working directory
  bash ./analyze_new_cluster.sh
else
  echo "    (analyze_new_cluster.sh not found — skipping; run manually if needed)"
fi

echo "==> pg_upgrade complete. New cluster is at ${NEW_DATA_DIR}"
