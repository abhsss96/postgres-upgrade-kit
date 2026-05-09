#!/bin/bash
set -euo pipefail

SCRIPTS_DIR="/usr/local/bin/pg-upgrade-scripts"

# Docker volumes are mounted as root:root by default. Fix ownership before
# dropping to the postgres user so scripts can write the upgrade report.
mkdir -p /reports
chown postgres:postgres /reports

case "${1:-}" in
  init-old)
    exec gosu postgres "${SCRIPTS_DIR}/init-old-cluster.sh"
    ;;
  upgrade)
    exec gosu postgres "${SCRIPTS_DIR}/run-upgrade.sh"
    ;;
  verify)
    exec gosu postgres "${SCRIPTS_DIR}/verify-new-cluster.sh"
    ;;
  *)
    echo "Usage: docker run <image> <command>"
    echo ""
    echo "Commands:"
    echo "  init-old   Initialize PostgreSQL ${OLD_PG_VERSION} cluster and create test databases"
    echo "  upgrade    Run pg_upgrade from ${OLD_PG_VERSION} to ${NEW_PG_VERSION}"
    echo "  verify     Start PostgreSQL ${NEW_PG_VERSION} and verify upgraded databases"
    exit 1
    ;;
esac
