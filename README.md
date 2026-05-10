# pg_upgrade — Containerized PostgreSQL Upgrade Utility

A Docker-based toolkit that automates upgrading PostgreSQL databases using `pg_upgrade`, built for teams running **containerized PostgreSQL in production**.

---

## The Problem

Upgrading PostgreSQL across major versions in a containerized environment is painful:

- `pg_upgrade` requires both the old and new PostgreSQL binaries to be present on the **same machine**
- The data directory must be accessible to both server processes during the upgrade
- After upgrade you need to prove the data survived intact before promoting the new cluster to production

This project packages all of that into reproducible Docker images and a CI pipeline that proves the upgrade works end-to-end before you touch production.

---

## How It Works

The upgrade runs as three container steps sharing data through Docker volumes:

```
┌──────────────────────────────────────────────────────────────────┐
│  Step 1 — init-old                                               │
│  Initialises a PostgreSQL <old> cluster with real-world schema:  │
│  tables, indexes, views, sequences, materialized views, FK       │
│  constraints, and sample data.                                   │
└──────────────────────┬───────────────────────────────────────────┘
                       │  pg-old-data volume / PVC
┌──────────────────────▼───────────────────────────────────────────┐
│  Step 2 — upgrade                                                │
│  Runs pg_upgrade --check (dry run), then the real upgrade.       │
│  Prints before/after directory snapshots, file sizes, and        │
│  structural renames (pg_xlog → pg_wal, pg_clog → pg_xact, etc.) │
└──────────────────────┬───────────────────────────────────────────┘
                       │  pg-new-data volume / PVC
┌──────────────────────▼───────────────────────────────────────────┐
│  Step 3 — verify                                                 │
│  Starts the new cluster and asserts:                             │
│  databases exist • row counts match • indexes intact             │
│  views work • sequences preserved • foreign keys survive         │
│  Prints a per-database size report on completion.                │
└──────────────────────────────────────────────────────────────────┘
```

---

## Supported Upgrade Paths

Images are published to **[abhsss/pg-upgrade on DockerHub](https://hub.docker.com/repository/docker/abhsss/pg-upgrade/general)**.

| From ↓  To → | PG 12 | PG 13 | PG 14 | PG 15 | PG 16 |
|---|:---:|:---:|:---:|:---:|:---:|
| **PG 9.6** | `9.6-to-12` | `9.6-to-13` | `9.6-to-14` | `9.6-to-15` | `9.6-to-16` |
| **PG 10**  | — | — | `10-to-14` | `10-to-15` | `10-to-16` |
| **PG 11**  | — | — | `11-to-14` | `11-to-15` | `11-to-16` |
| **PG 12**  | — | — | `12-to-14` | `12-to-15` | `12-to-16` |
| **PG 13**  | — | — | — | `13-to-15` | `13-to-16` |
| **PG 14**  | — | — | — | — | `14-to-16` |
| **PG 15**  | — | — | — | — | `15-to-16` |

Pull any image with:

```bash
docker pull abhsss/pg-upgrade:<tag>
# e.g.
docker pull abhsss/pg-upgrade:13-to-16
```

See [Adding a New Upgrade Path](#adding-a-new-upgrade-path) to request or contribute additional paths.

---

## Repository Structure

```
pg_upgrade/
├── Dockerfile                  # Generic parameterized build (accepts build args)
├── scripts/
│   ├── entrypoint.sh           # Dispatches init-old / upgrade / verify
│   ├── init-old-cluster.sh     # Seeds old cluster with schema-heavy test data
│   ├── install-extensions.sh   # Installs extension packages at build time
│   ├── run-upgrade.sh          # Runs pg_upgrade + prints before/after snapshots
│   └── verify-new-cluster.sh   # Asserts integrity + prints DB size report
├── .github/
│   └── workflows/
│       └── pg-upgrade.yml      # Matrix CI: builds all images, runs full pipeline
└── README.md
```

Every upgrade path is a set of build args passed to the same `Dockerfile`. Adding a new path is a one-file change to the CI matrix — no script changes needed.

---

## Quick Start (Local)

```bash
# 1. Build
docker build \
  --build-arg OLD_PG_VERSION=13 \
  --build-arg NEW_PG_VERSION=16 \
  -t pg-upgrade:13-to-16 .

# 2. Create volumes
docker volume create pg-old-data
docker volume create pg-new-data

# 3. Seed PostgreSQL 13 with test data
docker run --rm \
  -v pg-old-data:/var/lib/postgresql/13/main \
  pg-upgrade:13-to-16 init-old

# 4. Upgrade to PostgreSQL 16
docker run --rm \
  -v pg-old-data:/var/lib/postgresql/13/main \
  -v pg-new-data:/var/lib/postgresql/16/main \
  pg-upgrade:13-to-16 upgrade

# 5. Verify
docker run --rm \
  -v pg-new-data:/var/lib/postgresql/16/main \
  pg-upgrade:13-to-16 verify

# 6. Cleanup
docker volume rm pg-old-data pg-new-data
```

Or pull a pre-built image from DockerHub and skip step 1:

```bash
docker pull abhsss/pg-upgrade:13-to-16
```

---

## Kubernetes

The image runs without modification on Kubernetes. Replace Docker named volumes with PersistentVolumeClaims and `docker run` with Jobs.

### PersistentVolumeClaims

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pg-old-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 50Gi   # match your existing cluster size
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pg-new-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 60Gi   # allow ~20% headroom over old cluster size
```

### Step 1 — Seed old cluster (or skip if mounting an existing PVC)

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: pg-upgrade-init-old
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: pg-upgrade
          image: abhsss/pg-upgrade:9.6-to-16
          args: ["init-old"]
          volumeMounts:
            - name: pg-old-data
              mountPath: /var/lib/postgresql/9.6/main
      volumes:
        - name: pg-old-data
          persistentVolumeClaim:
            claimName: pg-old-data
```

### Step 2 — Run pg_upgrade

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: pg-upgrade-run
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: pg-upgrade
          image: abhsss/pg-upgrade:9.6-to-16
          args: ["upgrade"]
          volumeMounts:
            - name: pg-old-data
              mountPath: /var/lib/postgresql/9.6/main
            - name: pg-new-data
              mountPath: /var/lib/postgresql/16/main
      volumes:
        - name: pg-old-data
          persistentVolumeClaim:
            claimName: pg-old-data
        - name: pg-new-data
          persistentVolumeClaim:
            claimName: pg-new-data
```

### Step 3 — Verify

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: pg-upgrade-verify
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: pg-upgrade
          image: abhsss/pg-upgrade:9.6-to-16
          args: ["verify"]
          volumeMounts:
            - name: pg-new-data
              mountPath: /var/lib/postgresql/16/main
      volumes:
        - name: pg-new-data
          persistentVolumeClaim:
            claimName: pg-new-data
```

> **Tip:** Run each Job sequentially. Wait for `pg-upgrade-init-old` to reach `Completed` before applying `pg-upgrade-run`, and so on. You can chain them with `kubectl wait --for=condition=complete job/<name>`.

> **Production note:** For an actual production upgrade, replace the `init-old` step by mounting your existing PostgreSQL PVC directly into the upgrade Job. Ensure the old PostgreSQL StatefulSet/Deployment is scaled to zero before running the upgrade.

---

## Authentication and Credentials

**`pg_upgrade` does not require database passwords.** Here is why:

- `pg_upgrade` reads and writes data files directly on disk as the `postgres` OS user — it does not connect to a running server during the data migration itself
- The brief connections it makes during the pre-flight check use Unix socket / local trust authentication, which bypasses password auth entirely
- The `postgres` OS user (UID 999) already owns the data directory, so file access is handled by OS-level permissions, not database credentials

**What this means for your production upgrade:**

| Concern | Answer |
|---|---|
| Do I need to share my DB password? | No |
| Do I need to disable password auth first? | No — pg_upgrade never connects as an application user |
| Is the data directory safe? | Yes — the upgrade runs in an isolated container with only the mounted PVC |
| Are application credentials preserved? | Yes — `pg_hba.conf`, `pg_ident.conf`, and `pg_authid` (role passwords) are all migrated by pg_upgrade |

---

## CI Output

At the end of each run the upgrade and verify steps print a structured report directly in the CI log:

**After `upgrade`:**
```
──────────────────────────────────────────────────────────────────────
  Old cluster — PostgreSQL 9.6
──────────────────────────────────────────────────────────────────────
  Path:                /var/lib/postgresql/9.6/main
  Total size:          47M

  Directories:
    base/                                    38M
    global/                                   2M
    pg_xlog/                                  1M
    pg_clog/                                256K

  Notable structural changes applied during this upgrade:
    pg_xlog/                       → pg_wal/   (WAL directory, renamed in PG 10)
    pg_clog/                       → pg_xact/  (transaction status, renamed in PG 10)
    pg_log/                        → log/      (server log directory, renamed in PG 10)

  Post-upgrade scripts generated by pg_upgrade:
    ✓ analyze_new_cluster.sh        (in /var/lib/postgresql)
    ✓ delete_old_cluster.sh         (in /var/lib/postgresql)

──────────────────────────────────────────────────────────────────────
  Upgrade complete
──────────────────────────────────────────────────────────────────────
  Cluster size:                  47M → 49M  (+4%)
  Upgrade duration:              8s
  PostgreSQL version:            9.6 → 16
──────────────────────────────────────────────────────────────────────
```

**After `verify`:**
```
──────────────────────────────────────────────────────────────────────
  Database size report — PostgreSQL 16 (post-upgrade)
──────────────────────────────────────────────────────────────────────
  Database                                    Size
  --------                                    ----
  testdb                                    8192 kB
  analytics                                 6144 kB
  postgres                                  7455 kB

  Total cluster size:                         49M
──────────────────────────────────────────────────────────────────────
  Verification result — PostgreSQL 16
──────────────────────────────────────────────────────────────────────
  Passed:    9
  Failed:    0
──────────────────────────────────────────────────────────────────────
```

---

## Performance Estimates

`pg_upgrade` in **copy mode** (the default) re-writes every data file to the new cluster. Duration scales with cluster size and disk throughput.

> These are empirical estimates based on sequential I/O throughput. Actual times depend on the number of tables and indexes (catalog processing is CPU-bound and adds a flat overhead of a few seconds regardless of size).

| Cluster size | NVMe SSD (≥1 GB/s) | Cloud SSD (≈250 MB/s) | HDD (≈100 MB/s) | Link mode (`-k`) |
|---|---|---|---|---|
| 1 GB | ~2 s | ~5 s | ~15 s | < 5 s |
| 10 GB | ~15 s | ~45 s | ~2 min | < 5 s |
| 50 GB | ~1 min | ~4 min | ~10 min | < 5 s |
| 100 GB | ~2 min | ~7 min | ~20 min | < 5 s |
| 500 GB | ~10 min | ~35 min | ~90 min | < 5 s |
| 1 TB | ~20 min | ~70 min | ~3 h | < 5 s |

### Link mode (`-k`)

Add `-k` to the `pg_upgrade` call in `run-upgrade.sh` to use **hard links** instead of copying. The upgrade completes in seconds regardless of cluster size because no data is copied — the old and new clusters share the same underlying files.

**Trade-off:** After a link-mode upgrade, the old data directory is no longer independently valid. Do not run `delete_old_cluster.sh` until you have confirmed the new cluster is healthy in production.

### Read/Write throughput after upgrade

The upgraded cluster performs identically to a fresh PostgreSQL 16 installation on the same hardware. The upgrade process itself does not affect runtime I/O performance. Expect the standard PostgreSQL 16 throughput for your storage tier:

| Storage tier | Sequential read | Sequential write | Random IOPS (4K) |
|---|---|---|---|
| NVMe (e.g. AWS i3, GCP Local SSD) | 3–7 GB/s | 1–3 GB/s | 500K–1M |
| Cloud SSD (AWS gp3, GCP pd-ssd) | 500 MB/s–1 GB/s | 500 MB/s | 16K–64K |
| Cloud HDD (AWS st1, GCP pd-standard) | 250 MB/s | 250 MB/s | 500 |

---

## Adding a New Upgrade Path

Adding a path is a single-file change to `.github/workflows/pg-upgrade.yml`. Add one entry to the `build-and-push` matrix and one to the `test-upgrade` matrix:

```yaml
# build-and-push matrix
- { tag: "14-to-17", from: "14", to: "17", old_distro: "-bookworm", distro: "bookworm" }

# test-upgrade matrix
- { tag: "14-to-17", from: "14", to: "17" }
```

The `distro` field selects the Debian release for the runtime image (`postgres:<new>-<distro>`). Use `bookworm` for PG 17+. The `old_distro` suffix pins the source image to a specific Debian release to avoid GLIBC mismatches — use `-bookworm` for PG 12–17, leave empty for EOL versions (9.6, 10, 11).

No script changes are needed.

See [CONTRIBUTING.md](CONTRIBUTING.md) for a full walkthrough including how to test locally before opening a PR.

---

## Contributing

Contributions for additional upgrade paths, new extension support, improved verification queries, or production hardening are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions and guidelines.
