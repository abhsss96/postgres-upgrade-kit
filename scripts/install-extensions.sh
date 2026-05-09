#!/bin/bash
# Install PostgreSQL extension packages for a given PG major version.
# Usage: install-extensions.sh <pg-version> <ext1,ext2,...>
# Called at Docker build time from both Stage 1 (old PG) and Stage 2 (new PG).
set -euo pipefail

PG_VER="${1:?First argument must be the PostgreSQL major version}"
EXTENSIONS_CSV="${2:-}"

[ -z "${EXTENSIONS_CSV}" ] && exit 0

pkg_for() {
  local ext="${1}" ver="${2}"
  case "${ext}" in
    postgis)      echo "postgresql-${ver}-postgis-3" ;;
    pgvector)     echo "postgresql-${ver}-pgvector" ;;
    pg_partman)   echo "postgresql-${ver}-partman" ;;
    pgrouting)    echo "postgresql-${ver}-pgrouting" ;;
    pg_repack)    echo "postgresql-${ver}-repack" ;;
    hypopg)       echo "postgresql-${ver}-hypopg" ;;
    orafce)       echo "postgresql-${ver}-orafce" ;;
    rum)          echo "postgresql-${ver}-rum" ;;
    ip4r)         echo "postgresql-${ver}-ip4r" ;;
    pg_cron)      echo "postgresql-${ver}-cron" ;;
    pgaudit)      echo "postgresql-${ver}-pgaudit" ;;
    pg_hint_plan) echo "postgresql-${ver}-pg-hint-plan" ;;
    *) echo "Unknown extension: ${ext}" >&2; exit 1 ;;
  esac
}

PKGS=""
IFS=',' read -ra EXTS <<< "${EXTENSIONS_CSV}"
for ext in "${EXTS[@]}"; do
  ext="${ext// /}"
  [ -z "${ext}" ] && continue
  PKGS="${PKGS} $(pkg_for "${ext}" "${PG_VER}")"
done

[ -z "${PKGS// /}" ] && exit 0

apt-get update -qq
# shellcheck disable=SC2086
apt-get install -y --no-install-recommends ${PKGS}
rm -rf /var/lib/apt/lists/*
