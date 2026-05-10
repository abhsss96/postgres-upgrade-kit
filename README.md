## Repository Structure

```
pg_upgrade/
├── Dockerfile                  # Generic builder using OLD_PG_VERSION / NEW_PG_VERSION args
├── scripts/
│   ├── entrypoint.sh           # Dispatches init-old / upgrade / verify
│   ├── init-old-cluster.sh     # Seeds old cluster with schema-heavy test data
│   ├── install-extensions.sh   # Installs optional PostgreSQL extensions
│   ├── run-upgrade.sh          # Runs pg_upgrade + prints before/after snapshots
│   └── verify-new-cluster.sh   # Asserts integrity + prints DB size report
├── .github/
│   └── workflows/
│       └── pg-upgrade.yml      # Matrix CI: builds image, runs full pipeline
└── README.md
```

The repository uses a **single generic Dockerfile** that installs both PostgreSQL versions during build using the `OLD_PG_VERSION` and `NEW_PG_VERSION` build arguments. All upgrade logic lives in the shared scripts, so adding a new upgrade path requires only updating the CI matrix.

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

---

## Extensions Support

Some PostgreSQL upgrades require extensions (for example PostGIS) to exist in **both the old and new clusters** before running `pg_upgrade`.

The build supports installing extensions at image build time using the `EXTENSIONS` build argument. The installation is handled by `scripts/install-extensions.sh`.

Currently supported extensions include:

- `postgis`

Example:

```bash
docker build \
  --build-arg OLD_PG_VERSION=13 \
  --build-arg NEW_PG_VERSION=16 \
  --build-arg EXTENSIONS=postgis \
  -t pg-upgrade:13-to-16 .
```

Multiple extensions can be provided as a comma-separated list if additional installers are added in the future.

---

## Adding a New Upgrade Path

Upgrade paths are defined in the **CI matrix**.

Because the repository now uses a single generic `Dockerfile`, adding support for a new PostgreSQL version pair only requires updating the workflow configuration.

1. **Add the upgrade pair to the build matrix** in `.github/workflows/pg-upgrade.yml`:

```yaml
- { tag: "14-to-17", from: "14", to: "17" }
```

2. The CI pipeline will:

- build the image using the root `Dockerfile`
- pass `OLD_PG_VERSION` and `NEW_PG_VERSION` as build args
- run the full `init-old → upgrade → verify` pipeline

No Dockerfiles or scripts need to be added for new upgrade combinations.
