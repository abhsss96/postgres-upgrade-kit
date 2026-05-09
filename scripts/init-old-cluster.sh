#!/bin/bash
set -euo pipefail

OLD_PG_VERSION="${OLD_PG_VERSION:?OLD_PG_VERSION env var must be set}"
NEW_PG_VERSION="${NEW_PG_VERSION:?NEW_PG_VERSION env var must be set}"
OLD_DATA_DIR="/var/lib/postgresql/${OLD_PG_VERSION}/main"
OLD_BIN="/usr/lib/postgresql/${OLD_PG_VERSION}/bin"
# Use the new version's psql — it is backward-compatible with older servers
# and avoids libreadline ABI mismatches between the source and target distros.
PSQL="/usr/lib/postgresql/${NEW_PG_VERSION}/bin/psql"
REPORT_FILE="/reports/upgrade.md"
OLD_DB_SIZES_FILE="/reports/old-db-sizes.txt"

hr() { printf '%.0s─' {1..70}; echo; }
has_report() { [ -d "/reports" ] && [ -w "/reports" ]; }
rpt() { has_report && echo "$1" >> "${REPORT_FILE}" || true; }

echo "==> Initializing PostgreSQL ${OLD_PG_VERSION} cluster at ${OLD_DATA_DIR}"
"${OLD_BIN}/initdb" \
  -D "${OLD_DATA_DIR}" \
  --encoding=UTF8 \
  --locale=en_US.UTF-8

# Allow local connections without password
echo "host all all 127.0.0.1/32 trust" >> "${OLD_DATA_DIR}/pg_hba.conf"
echo "host all all ::1/128 trust"       >> "${OLD_DATA_DIR}/pg_hba.conf"

echo "==> Starting PostgreSQL ${OLD_PG_VERSION}"
"${OLD_BIN}/pg_ctl" -D "${OLD_DATA_DIR}" -l "${OLD_DATA_DIR}/pg.log" start -w

echo "==> Creating testdb with schema-heavy fixtures"
"${PSQL}" -U postgres -h 127.0.0.1 -c "CREATE DATABASE testdb;"

"${PSQL}" -U postgres -h 127.0.0.1 -d testdb <<'SQL'
CREATE TABLE users (
    id         SERIAL PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    email      VARCHAR(255) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    CONSTRAINT users_email_unique UNIQUE (email)
);

CREATE TABLE orders (
    id         SERIAL PRIMARY KEY,
    user_id    INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    amount     DECIMAL(10, 2) NOT NULL,
    status     VARCHAR(20) NOT NULL DEFAULT 'pending',
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_orders_user_id ON orders(user_id);
CREATE INDEX idx_orders_status  ON orders(status);

CREATE VIEW active_orders AS
    SELECT o.id, o.amount, o.status, o.created_at, u.name AS user_name, u.email
    FROM orders o
    JOIN users u ON u.id = o.user_id
    WHERE o.status = 'pending';

CREATE SEQUENCE invoice_seq START 1000 INCREMENT 1;

INSERT INTO users (name, email) VALUES
    ('Alice Smith',    'alice@example.com'),
    ('Bob Johnson',    'bob@example.com'),
    ('Carol Williams', 'carol@example.com');

INSERT INTO orders (user_id, amount, status) VALUES
    (1, 99.99,  'pending'),
    (1, 249.00, 'completed'),
    (2, 149.99, 'pending'),
    (3, 49.50,  'cancelled');
SQL

echo "==> Creating analytics database"
"${PSQL}" -U postgres -h 127.0.0.1 -c "CREATE DATABASE analytics;"

"${PSQL}" -U postgres -h 127.0.0.1 -d analytics <<'SQL'
CREATE TABLE events (
    id         BIGSERIAL PRIMARY KEY,
    event_type VARCHAR(50) NOT NULL,
    user_id    INT,
    payload    TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_events_type_time ON events(event_type, created_at);

INSERT INTO events (event_type, user_id, payload) VALUES
    ('login',    1, '{"ip": "1.2.3.4"}'),
    ('purchase', 1, '{"order_id": 1}'),
    ('login',    2, '{"ip": "5.6.7.8"}'),
    ('logout',   1, NULL),
    ('purchase', 3, '{"order_id": 3}');

CREATE MATERIALIZED VIEW daily_event_counts AS
    SELECT
        DATE_TRUNC('day', created_at) AS day,
        event_type,
        COUNT(*) AS event_count
    FROM events
    GROUP BY 1, 2;

CREATE INDEX idx_daily_event_counts_day ON daily_event_counts(day);
SQL

# Save per-DB sizes while the old cluster is still running.
if has_report; then
  "${PSQL}" -U postgres -h 127.0.0.1 -d postgres -tAc "
    SELECT datname || '|' || pg_size_pretty(pg_database_size(datname))
    FROM pg_database
    WHERE datname NOT IN ('template0','template1')
    ORDER BY pg_database_size(datname) DESC;
  " > "${OLD_DB_SIZES_FILE}"
fi

echo "==> Stopping PostgreSQL ${OLD_PG_VERSION}"
"${OLD_BIN}/pg_ctl" -D "${OLD_DATA_DIR}" stop -m fast

# ── Snapshot old cluster ──────────────────────────────────────────────────────

echo ""
echo "==> Snapshotting old cluster after initialization"
hr
printf "  %s\n" "Old cluster — PostgreSQL ${OLD_PG_VERSION}"
printf "  %-20s %s\n" "Path:"       "${OLD_DATA_DIR}"
printf "  %-20s %s\n" "Total size:" "$(du -sh "${OLD_DATA_DIR}" 2>/dev/null | cut -f1)"
hr

echo "  Directories:"
while IFS= read -r line; do
  size=$(echo "$line" | awk '{print $1}')
  dir=$( echo "$line" | awk '{print $2}' | sed "s|${OLD_DATA_DIR}/||")
  printf "    %-40s %s\n" "${dir}/" "${size}"
done < <(du -sh "${OLD_DATA_DIR}"/*/  2>/dev/null | sort -rh)

echo "  Files:"
while IFS= read -r f; do
  size=$(du -sh "${f}" 2>/dev/null | cut -f1)
  printf "    %-40s %s\n" "$(basename "${f}")" "${size}"
done < <(find "${OLD_DATA_DIR}" -maxdepth 1 -type f | sort)

if has_report; then
  cat > "${REPORT_FILE}" <<MD
## pg_upgrade — PostgreSQL ${OLD_PG_VERSION} → ${NEW_PG_VERSION}

### Cluster snapshots

#### Old cluster — PostgreSQL ${OLD_PG_VERSION} (post-init)

| Path | Size |
|---|---|
| **Total** | **$(du -sh "${OLD_DATA_DIR}" 2>/dev/null | cut -f1)** |
MD
  while IFS= read -r line; do
    size=$(echo "$line" | awk '{print $1}')
    dir=$( echo "$line" | awk '{print $2}' | sed "s|${OLD_DATA_DIR}/||")
    rpt "| \`${dir}/\` | ${size} |"
  done < <(du -sh "${OLD_DATA_DIR}"/*/  2>/dev/null | sort -rh)
  while IFS= read -r f; do
    size=$(du -sh "${f}" 2>/dev/null | cut -f1)
    rpt "| \`$(basename "${f}")\` | ${size} |"
  done < <(find "${OLD_DATA_DIR}" -maxdepth 1 -type f | sort)
fi

echo ""
echo "==> PostgreSQL ${OLD_PG_VERSION} cluster initialized with test data."
