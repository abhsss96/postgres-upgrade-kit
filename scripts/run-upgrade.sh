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
rpt() { has_report && echo "$1" >> "${REPORT_FILE}" || true; }

# Prints a side-by-side comparison of old vs new cluster directories to stdout
# and appends a markdown table to the report.
compare_clusters() {
  local old_dir="$1" new_dir="$2"
  local tmp_old tmp_new
  tmp_old=$(mktemp) && tmp_new=$(mktemp)

  du -sh "${old_dir}"/*/  2>/dev/null | sort -rh | \
    awk -v base="${old_dir}/" '{size=$1; path=$2; sub(base,"",path); sub("/$","",path); print path, size}' \
    > "${tmp_old}"

  du -sh "${new_dir}"/*/  2>/dev/null | sort -rh | \
    awk -v base="${new_dir}/" '{size=$1; path=$2; sub(base,"",path); sub("/$","",path); print path, size}' \
    > "${tmp_new}"

  local old_total new_total
  old_total=$(du -sh "${old_dir}" 2>/dev/null | cut -f1)
  new_total=$(du -sh "${new_dir}" 2>/dev/null | cut -f1)

  local all_dirs
  all_dirs=$(awk '{print $1}' "${tmp_old}" "${tmp_new}" | sort -u)

  # ── stdout ──
  echo ""; hr
  printf "  %-35s %-10s %s\n" "Directory" "PG ${OLD_PG_VERSION}" "PG ${NEW_PG_VERSION}"
  printf "  %-35s %-10s %s\n" "---------" "----------" "----------"
  printf "  %-35s %-10s %s\n" "(total)" "${old_total}" "${new_total}"
  while IFS= read -r dir; do
    [ -z "${dir}" ] && continue
    old_size=$(awk -v d="${dir}" '$1==d{print $2}' "${tmp_old}")
    new_size=$(awk -v d="${dir}" '$1==d{print $2}' "${tmp_new}")
    [ -z "${old_size}" ] && old_size="—"
    [ -z "${new_size}" ] && new_size="—"
    printf "  %-35s %-10s %s\n" "${dir}/" "${old_size}" "${new_size}"
  done <<< "${all_dirs}"
  hr

  # ── markdown report ──
  if has_report; then
    rpt ""
    rpt "### Cluster comparison"
    rpt ""
    rpt "| Directory | PostgreSQL ${OLD_PG_VERSION} | PostgreSQL ${NEW_PG_VERSION} |"
    rpt "|---|---|---|"
    rpt "| **Total** | **${old_total}** | **${new_total}** |"
    while IFS= read -r dir; do
      [ -z "${dir}" ] && continue
      old_size=$(awk -v d="${dir}" '$1==d{print $2}' "${tmp_old}")
      new_size=$(awk -v d="${dir}" '$1==d{print $2}' "${tmp_new}")
      [ -z "${old_size}" ] && old_size="—"
      [ -z "${new_size}" ] && new_size="—"
      rpt "| \`${dir}/\` | ${old_size} | ${new_size} |"
    done <<< "${all_dirs}"
  fi

  rm -f "${tmp_old}" "${tmp_new}"
}

# ── Initialise new cluster ────────────────────────────────────────────────────

echo ""
echo "==> Initializing PostgreSQL ${NEW_PG_VERSION} cluster at ${NEW_DATA_DIR}"
"${NEW_BIN}/initdb" \
  -D "${NEW_DATA_DIR}" \
  --encoding=UTF8 \
  --locale=en_US.UTF-8

# ── Compatibility check ───────────────────────────────────────────────────────

_print_pg_upgrade_logs() {
  local out_dir
  out_dir=$(find "${NEW_DATA_DIR}/pg_upgrade_output.d" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)
  [ -z "${out_dir}" ] && return
  for f in "${out_dir}"/loadable_libraries.txt "${out_dir}"/log/*.log; do
    [ -f "${f}" ] || continue
    echo "==> $(basename "${f}"):"
    cat "${f}"
    echo ""
  done
}

echo ""
echo "==> Running pg_upgrade compatibility check (dry run)"
"${NEW_BIN}/pg_upgrade" \
  -b "${OLD_BIN}" \
  -B "${NEW_BIN}" \
  -d "${OLD_DATA_DIR}" \
  -D "${NEW_DATA_DIR}" \
  --check || { _print_pg_upgrade_logs; exit 1; }

# ── Real upgrade ──────────────────────────────────────────────────────────────

echo ""
echo "==> Compatibility check passed. Running pg_upgrade"
UPGRADE_START=$(date +%s)

"${NEW_BIN}/pg_upgrade" \
  -b "${OLD_BIN}" \
  -B "${NEW_BIN}" \
  -d "${OLD_DATA_DIR}" \
  -D "${NEW_DATA_DIR}" \
|| { _print_pg_upgrade_logs; exit 1; }

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

# ── Cluster comparison ───────────────────────────────────────────────────────

echo ""
echo "==> Cluster comparison — PostgreSQL ${OLD_PG_VERSION} → ${NEW_PG_VERSION}"
compare_clusters "${OLD_DATA_DIR}" "${NEW_DATA_DIR}"

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
