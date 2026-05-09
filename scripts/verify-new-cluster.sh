#!/bin/bash
set -euo pipefail

NEW_PG_VERSION="${NEW_PG_VERSION:?NEW_PG_VERSION env var must be set}"
NEW_DATA_DIR="/var/lib/postgresql/${NEW_PG_VERSION}/main"
NEW_BIN="/usr/lib/postgresql/${NEW_PG_VERSION}/bin"
PSQL="${NEW_BIN}/psql"

hr() { printf '%.0s─' {1..70}; echo; }

echo "==> Starting PostgreSQL ${NEW_PG_VERSION}"
"${NEW_BIN}/pg_ctl" -D "${NEW_DATA_DIR}" -l "${NEW_DATA_DIR}/pg.log" start -w

if ! grep -q "127.0.0.1/32 trust" "${NEW_DATA_DIR}/pg_hba.conf"; then
  echo "host all all 127.0.0.1/32 trust" >> "${NEW_DATA_DIR}/pg_hba.conf"
  echo "host all all ::1/128 trust"       >> "${NEW_DATA_DIR}/pg_hba.conf"
  "${NEW_BIN}/pg_ctl" -D "${NEW_DATA_DIR}" reload
fi

PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; (( PASS++ )) || true; }
fail() {
  echo "  [FAIL] $1"
  (( FAIL++ )) || true
  "${NEW_BIN}/pg_ctl" -D "${NEW_DATA_DIR}" stop -m fast
  exit 1
}

run_sql() { "${PSQL}" -U postgres -h 127.0.0.1 -d "$1" -tAc "$2"; }

# ── Integrity checks ──────────────────────────────────────────────────────────

echo ""
echo "==> Verifying databases"
for db in testdb analytics; do
  result=$(run_sql postgres "SELECT 1 FROM pg_database WHERE datname = '${db}';")
  [ "${result}" = "1" ] && pass "Database '${db}' exists" || fail "Database '${db}' missing"
done

echo ""
echo "==> Verifying tables and row counts"
user_count=$(run_sql testdb "SELECT COUNT(*) FROM users;")
[ "${user_count}" -ge 3 ]  && pass "users: ${user_count} rows"  || fail "users: unexpected count ${user_count}"

order_count=$(run_sql testdb "SELECT COUNT(*) FROM orders;")
[ "${order_count}" -ge 4 ] && pass "orders: ${order_count} rows" || fail "orders: unexpected count ${order_count}"

evt_count=$(run_sql analytics "SELECT COUNT(*) FROM events;")
[ "${evt_count}" -ge 5 ]   && pass "events: ${evt_count} rows"  || fail "events: unexpected count ${evt_count}"

echo ""
echo "==> Verifying schema objects"
view_count=$(run_sql testdb "SELECT COUNT(*) FROM active_orders;")
[ "${view_count}" -ge 1 ] && pass "View active_orders queryable (${view_count} rows)" || fail "View active_orders returned 0 rows"

seq_val=$(run_sql testdb "SELECT nextval('invoice_seq');")
[ "${seq_val}" -ge 1000 ]  && pass "Sequence invoice_seq = ${seq_val}" || fail "Sequence invoice_seq unexpected: ${seq_val}"

idx_count=$(run_sql testdb "SELECT COUNT(*) FROM pg_indexes WHERE tablename = 'orders' AND indexname LIKE 'idx_%';")
[ "${idx_count}" -ge 2 ]   && pass "orders: ${idx_count} custom indexes intact" || fail "orders indexes missing (found ${idx_count})"

fk_count=$(run_sql testdb "SELECT COUNT(*) FROM information_schema.table_constraints WHERE constraint_type = 'FOREIGN KEY' AND table_name = 'orders';")
[ "${fk_count}" -ge 1 ]    && pass "orders: foreign key constraint intact" || fail "orders: foreign key constraint missing"

mv_count=$(run_sql analytics "SELECT COUNT(*) FROM daily_event_counts;")
[ "${mv_count}" -ge 1 ]    && pass "Materialized view daily_event_counts: ${mv_count} rows" || fail "Materialized view daily_event_counts empty"

# ── Per-database size report ──────────────────────────────────────────────────

echo ""
hr
echo "  Database size report — PostgreSQL ${NEW_PG_VERSION} (post-upgrade)"
hr
printf "  %-30s %15s\n" "Database" "Size"
printf "  %-30s %15s\n" "--------" "----"
while IFS='|' read -r dbname size; do
  printf "  %-30s %15s\n" "${dbname}" "${size}"
done < <(run_sql postgres "
  SELECT datname, pg_size_pretty(pg_database_size(datname))
  FROM pg_database
  WHERE datname NOT IN ('template0','template1')
  ORDER BY pg_database_size(datname) DESC;
")
echo ""
printf "  %-30s %15s\n" "Total cluster size:" "$(du -sh "${NEW_DATA_DIR}" 2>/dev/null | cut -f1)"
hr

# ── Summary ───────────────────────────────────────────────────────────────────

"${NEW_BIN}/pg_ctl" -D "${NEW_DATA_DIR}" stop -m fast

echo ""
hr
echo "  Verification result — PostgreSQL ${NEW_PG_VERSION}"
hr
printf "  %-10s %d\n" "Passed:" "${PASS}"
printf "  %-10s %d\n" "Failed:" "${FAIL}"
hr
echo ""
echo "==> All checks passed. PostgreSQL ${NEW_PG_VERSION} upgrade is healthy."
