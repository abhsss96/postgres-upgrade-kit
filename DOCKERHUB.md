# DockerHub Repository Description

Use the content below when updating the DockerHub repository at
https://hub.docker.com/repository/docker/abhsss/pg-upgrade/general

---

## Short description

> 100 characters max — paste into the **Short Description** field.

```
Docker images for PostgreSQL major-version upgrades using pg_upgrade. Built for containerized prod.
```

---

## Full description

> Paste into the **Overview** tab. DockerHub renders standard Markdown.

---

# pg-upgrade

Docker images that automate PostgreSQL major-version upgrades using `pg_upgrade`, built for teams running **containerized PostgreSQL in production**.

Each image contains both the old and new PostgreSQL binaries. The upgrade runs in three isolated container steps connected by Docker volumes (or Kubernetes PersistentVolumeClaims), so no data ever leaves your infrastructure.

## Supported upgrade paths

| From ↓  To → | PG 12 | PG 13 | PG 14 | PG 15 | PG 16 |
|---|:---:|:---:|:---:|:---:|:---:|
| **PG 9.6** | `9.6-to-12` | `9.6-to-13` | `9.6-to-14` | `9.6-to-15` | `9.6-to-16` |
| **PG 10**  | — | — | `10-to-14` | `10-to-15` | `10-to-16` |
| **PG 11**  | — | — | `11-to-14` | `11-to-15` | `11-to-16` |
| **PG 12**  | — | — | `12-to-14` | `12-to-15` | `12-to-16` |
| **PG 13**  | — | — | — | `13-to-15` | `13-to-16` |
| **PG 14**  | — | — | — | — | `14-to-16` |
| **PG 15**  | — | — | — | — | `15-to-16` |

## Quick start

```bash
# Step 1 — seed the old cluster with test data
docker run --rm \
  -v pg-old-data:/var/lib/postgresql/13/main \
  abhsss/pg-upgrade:13-to-16 init-old

# Step 2 — run pg_upgrade (prints before/after snapshots and timing)
docker run --rm \
  -v pg-old-data:/var/lib/postgresql/13/main \
  -v pg-new-data:/var/lib/postgresql/16/main \
  abhsss/pg-upgrade:13-to-16 upgrade

# Step 3 — verify integrity of the upgraded cluster
docker run --rm \
  -v pg-new-data:/var/lib/postgresql/16/main \
  abhsss/pg-upgrade:13-to-16 verify
```

## What the upgrade step prints

- Directory snapshot of the old cluster (sizes, config files)
- Structural renames applied (`pg_xlog → pg_wal`, `pg_clog → pg_xact`, etc.)
- Directory snapshot of the new cluster after upgrade
- Size delta and wall-clock duration
- Locations of the generated `analyze_new_cluster.sh` and `delete_old_cluster.sh` scripts

## What the verify step prints

- Per-database size report (queried live from `pg_database`)
- Pass/fail count across all integrity checks (row counts, indexes, views, sequences, foreign keys, materialized views)

## No credentials required

`pg_upgrade` works directly on data files as the `postgres` OS user. No database password is involved at any stage of the upgrade.

## Kubernetes

The image runs unmodified on Kubernetes. Replace Docker volumes with PersistentVolumeClaims and `docker run` with Jobs. Full manifests and step-by-step instructions are in the [GitHub repository](https://github.com/abhsss96/postgres-upgrade-kit).

## Source

[github.com/abhsss96/postgres-upgrade-kit](https://github.com/abhsss96/postgres-upgrade-kit)
