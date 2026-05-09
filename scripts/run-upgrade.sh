#!/bin/bash
set -euo pipefail

OLD_PG_VERSION="${OLD_PG_VERSION:?OLD_PG_VERSION env var must be set}"
NEW_PG_VERSION="${NEW_PG_VERSION:?NEW_PG_VERSION env var must be set}"
OLD_DATA_DIR="/var/lib/postgresql/${OLD_PG_VERSION}/main"
NEW_DATA_DIR="/var/lib/postgresql/${NEW_PG_VERSION}/main"
OLD_BIN="/usr/lib/postgresql/${OLD_PG_VERSION}/bin"
NEW_BIN="/usr/lib/postgresql/${NEW_PG_VERSION}/bin"
WORK_DIR="/var/lib/postgresql"
REPORT_FILE="/reports/upgrade.md"

# pg_upgrade writes log files and post-upgrade scripts to the current
# working directory, which must be writable by the postgres user.
cd "${WORK_DIR}"

# ── Helpers ───────────────────────────────────────────────────────────────────

hr() { printf '%.0s─' {1..70}; echo; }
has_report() { [ -d "/reports" ] && [ -w "/reports" ]; }
rpt() { has_report && echo "$1" >> "${REPORT_FILE}"; }

# Writes a directory-breakdown table to stdout (plain) and report (markdown).
snapshot_dirs() {
  local label="$1" data_dir="$2"

  echo ""; hr
  printf "  %s\n" "${label}"
  printf "  %-20s %s\n" "Path:"        "${data_dir}"
  printf "  %-20s %s\n" "Total size:"  "$(du -sh "${data_dir}" 2>/dev/null | cut -f1)"
  hr

  echo "  Directories:"
  while IFS= read -r line; do
    size=$(echo "$line" | awk '{print $1}')
    dir=$( echo "$line" | awk '{print $2}' | sed "s|${data_dir}/||")
    printf "    %-40s %s\n" "${dir}/" "${size}"
  done < <(du -sh "${data_dir}"/*/  2>/dev/null | sort -rh)

  echo "  Files:"
  while IFS= read -r f; do
    size=$(du -sh "${f}" 2>/dev/null | cut -f1)
    printf "    %-40s %s\n" "$(basename "${f}")" "${size}"
  done < <(find "${data_dir}" -maxdepth 1 -type f | sort)

  if has_report; then
    rpt ""
    rpt "#### ${label}"
    rpt ""
    rpt "| Path | Size |"
    rpt "|---|---|"
    rpt "| **Total** | **$(du -sh "${data_dir}" 2>/dev/null \| cut -f1)** |"
    while IFS= read -r line; do
      size=$(echo "$line" | awk '{print $1}')
      dir=$( echo "$line" | awk '{print $2}' | sed "s|${data_dir}/||")
      rpt "| \`${dir}/\` | ${size} |"
    done < <(du -sh "${data_dir}"/*/  2>/dev/null | sort -rh)
    while IFS= read -r f; do
      size=$(du -sh "${f}" 2>/dev/null | cut -f1)
      rpt "| \`$(basename "${f}")\` | ${size} |"
    done < <(find "${data_dir}" -maxdepth 1 -type f | sort)
  fi
}

# ── Initialise report ─────────────────────────────────────────────────────────

if has_report; then
  cat > "${REPORT_FILE}" <<MD
## pg_upgrade — PostgreSQL ${OLD_PG_VERSION} → ${NEW_PG_VERSION}

### Cluster snapshots
MD
fi

# ── Snapshot old cluster ──────────────────────────────────────────────────────

echo "==> Snapshotting old cluster before upgrade"
snapshot_dirs "Old cluster — PostgreSQL ${OLD_PG_VERSION}" "${OLD_DATA_DIR}"

# ── Initialise new cluster ────────────────────────────────────────────────────

echo ""
echo "==> Initializing PostgreSQL ${NEW_PG_VERSION} cluster at ${NEW_DATA_DIR}"
"${NEW_BIN}/initdb" \
  -D "${NEW_DATA_DIR}" \
  --encoding=UTF8 \
  --locale=en_US.UTF-8

# ── Compatibility check ───────────────────────────────────────────────────────

echo ""
echo "==> Running pg_upgrade compatibility check (dry run)"
"${NEW_BIN}/pg_upgrade" \
  -b "${OLD_BIN}" \
  -B "${NEW_BIN}" \
  -d "${OLD_DATA_DIR}" \
  -D "${NEW_DATA_DIR}" \
  --check

# ── Real upgrade ──────────────────────────────────────────────────────────────

echo ""
echo "==> Compatibility check passed. Running pg_upgrade"
UPGRADE_START=$(date +%s)

"${NEW_BIN}/pg_upgrade" \
  -b "${OLD_BIN}" \
  -B "${NEW_BIN}" \
  -d "${OLD_DATA_DIR}" \
  -D "${NEW_DATA_DIR}"

UPGRADE_END=$(date +%s)
UPGRADE_SECS=$(( UPGRADE_END - UPGRADE_START ))

# ── Post-upgrade ANALYZE ──────────────────────────────────────────────────────

echo ""
echo "==> Running post-upgrade ANALYZE on all databases"
if [ -f "${WORK_DIR}/analyze_new_cluster.sh" ]; then
  bash "${WORK_DIR}/analyze_new_cluster.sh"
else
  echo "    (analyze_new_cluster.sh not found — skipping)"
fi

# ── Snapshot new cluster ──────────────────────────────────────────────────────

echo ""
echo "==> Snapshotting new cluster after upgrade"
snapshot_dirs "New cluster — PostgreSQL ${NEW_PG_VERSION}" "${NEW_DATA_DIR}"

# ── Structural renames ────────────────────────────────────────────────────────

OLD_MAJOR=$(echo "${OLD_PG_VERSION}" | cut -d. -f1)

if [ "${OLD_MAJOR}" -lt 10 ]; then
  echo ""
  echo "  Structural renames applied (PG 9.x → 10+):"
  printf "    %-20s → %s\n" "pg_xlog/"  "pg_wal/"
  printf "    %-20s → %s\n" "pg_clog/"  "pg_xact/"
  printf "    %-20s → %s\n" "pg_log/"   "log/"

  if has_report; then
    rpt ""
    rpt "### Structural renames applied"
    rpt ""
    rpt "| Old path | New path | Reason |"
    rpt "|---|---|---|"
    rpt "| \`pg_xlog/\` | \`pg_wal/\` | WAL directory renamed in PG 10 |"
    rpt "| \`pg_clog/\` | \`pg_xact/\` | Transaction status renamed in PG 10 |"
    rpt "| \`pg_log/\` | \`log/\` | Server log directory renamed in PG 10 |"
  fi
fi

# ── Post-upgrade scripts ──────────────────────────────────────────────────────

echo ""
echo "  Post-upgrade scripts generated by pg_upgrade:"
if has_report; then
  rpt ""
  rpt "### Post-upgrade scripts"
  rpt ""
  rpt "| Script | Purpose |"
  rpt "|---|---|"
fi

for script in analyze_new_cluster.sh delete_old_cluster.sh; do
  if [ -f "${WORK_DIR}/${script}" ]; then
    echo "    ✓ ${script} (in ${WORK_DIR})"
    if has_report; then
      case "$script" in
        analyze*) purpose="Run ANALYZE on all databases to refresh query planner statistics" ;;
        delete*)  purpose="Remove old cluster files after confirming the new cluster is healthy" ;;
      esac
      rpt "| \`${script}\` | ${purpose} |"
    fi
  fi
done

# ── Upgrade summary ───────────────────────────────────────────────────────────

OLD_SIZE_KB=$(du -sk "${OLD_DATA_DIR}" 2>/dev/null | cut -f1)
NEW_SIZE_KB=$(du -sk "${NEW_DATA_DIR}" 2>/dev/null | cut -f1)
OLD_SIZE_HR=$(du -sh "${OLD_DATA_DIR}" 2>/dev/null | cut -f1)
NEW_SIZE_HR=$(du -sh "${NEW_DATA_DIR}" 2>/dev/null | cut -f1)
OVERHEAD=$(( OLD_SIZE_KB > 0 ? (NEW_SIZE_KB - OLD_SIZE_KB) * 100 / OLD_SIZE_KB : 0 ))

echo ""; hr
echo "  Upgrade complete"
hr
printf "  %-30s %s → %s  (%+d%%)\n" "Cluster size:" "${OLD_SIZE_HR}" "${NEW_SIZE_HR}" "${OVERHEAD}"
printf "  %-30s %ds\n"               "Duration:"     "${UPGRADE_SECS}"
printf "  %-30s %s → %s\n"           "Version:"      "${OLD_PG_VERSION}" "${NEW_PG_VERSION}"
hr

if has_report; then
  rpt ""
  rpt "### Upgrade summary"
  rpt ""
  rpt "| Metric | Value |"
  rpt "|---|---|"
  rpt "| PostgreSQL version | \`${OLD_PG_VERSION}\` → \`${NEW_PG_VERSION}\` |"
  rpt "| Cluster size | ${OLD_SIZE_HR} → ${NEW_SIZE_HR} ($(printf '%+d' "${OVERHEAD}")%) |"
  rpt "| Duration | ${UPGRADE_SECS}s |"
fi
