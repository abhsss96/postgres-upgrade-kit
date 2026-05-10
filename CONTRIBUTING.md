# Contributing to pg_upgrade

Thank you for your interest in contributing. This guide covers everything you need to set up a local development environment, test changes, and open a pull request.

---

## Prerequisites

| Tool | Minimum version | Purpose |
|---|---|---|
| Docker | 24+ | Build and run upgrade images |
| Docker Buildx | bundled with Docker 24 | Multi-platform builds |
| Git | any recent | Version control |

No PostgreSQL installation is required — everything runs inside Docker.

---

## Setting Up Locally

```bash
git clone https://github.com/<your-fork>/pg_upgrade.git
cd pg_upgrade
```

Verify Docker Buildx is available:

```bash
docker buildx version
```

---

## Building an Image

The repo has a single generic `Dockerfile` that is parameterized via build args:

```bash
docker build \
  --build-arg OLD_PG_VERSION=13 \
  --build-arg NEW_PG_VERSION=16 \
  --build-arg NEW_PG_DISTRO=bookworm \
  -t pg-upgrade:13-to-16 \
  .
```

| Build arg | Description | Example values |
|---|---|---|
| `OLD_PG_VERSION` | Source PostgreSQL major version | `9.6`, `13`, `15` |
| `NEW_PG_VERSION` | Target PostgreSQL major version | `14`, `15`, `16` |
| `NEW_PG_DISTRO` | Debian release for the runtime image | `bullseye`, `bookworm` |
| `OLD_PG_IMAGE` | Full image spec for the old-binaries stage | `postgis/postgis:13-3.4` |
| `EXTENSIONS` | Comma-separated list of extensions to install | `postgis`, `postgis,pgvector` |

Use `bullseye` as `NEW_PG_DISTRO` for all currently supported paths (PG 12–16). Use `bookworm` when adding PG 17+ targets.

Use `--no-cache` when iterating on `Dockerfile` or `scripts/install-extensions.sh` to avoid stale build layers.

---

## Running the Full Upgrade Pipeline Locally

These three steps mirror exactly what the CI `test-upgrade` job runs.

**1. Create volumes**

```bash
docker volume create pg-old-data
docker volume create pg-new-data
docker volume create pg-reports
```

**2. Initialise the old cluster**

```bash
docker run --rm \
  -v pg-old-data:/var/lib/postgresql/13/main \
  -v pg-reports:/reports \
  pg-upgrade:13-to-16 \
  init-old
```

**3. Run the upgrade**

```bash
docker run --rm \
  -v pg-old-data:/var/lib/postgresql/13/main \
  -v pg-new-data:/var/lib/postgresql/16/main \
  -v pg-reports:/reports \
  pg-upgrade:13-to-16 \
  upgrade
```

**4. Verify the new cluster**

```bash
docker run --rm \
  -v pg-new-data:/var/lib/postgresql/16/main \
  -v pg-reports:/reports \
  pg-upgrade:13-to-16 \
  verify
```

**5. Clean up**

```bash
docker volume rm pg-old-data pg-new-data pg-reports
```

---

## Apple Silicon (M1 / M2 / M3)

Some older source images (notably `postgis/postgis:9.6-3.0` and `postgis/postgis:11-3.1`) are only published for `linux/amd64`. On Apple Silicon you must add `--platform linux/amd64` to every `docker build` and `docker run` command for those paths. Docker uses QEMU emulation automatically — no extra setup is needed beyond passing the flag.

```bash
docker build --platform linux/amd64 \
  --build-arg OLD_PG_IMAGE=postgis/postgis:9.6-3.0 \
  --build-arg OLD_PG_VERSION=9.6 \
  --build-arg NEW_PG_VERSION=16 \
  --build-arg NEW_PG_DISTRO=bullseye \
  --build-arg EXTENSIONS=postgis \
  -t pg-upgrade:9.6-to-16-postgis \
  .
```

Standard paths (no `old_image` override) use the official `postgres` images which publish arm64 variants, so no `--platform` flag is needed for those.

---

## Testing PostGIS Paths

PostGIS paths require the old cluster to be initialised inside the source `postgis/postgis` image (not the pg-upgrade image) so that `CREATE EXTENSION postgis` works against the correct binaries. This mirrors the CI workflow exactly.

**Step 1 — fix volume ownership (runs as root)**

```bash
docker run --rm --platform linux/amd64 \
  -v "pg-old-data:/var/lib/postgresql/9.6/main" \
  -v "pg-reports:/reports" \
  postgis/postgis:9.6-3.0 \
  chown postgres:postgres /reports /var/lib/postgresql/9.6/main
```

**Step 2 — init old cluster (runs as postgres)**

```bash
docker run --rm --platform linux/amd64 \
  -v "$PWD/scripts/init-old-cluster.sh:/init-old-cluster.sh:ro" \
  -v "pg-old-data:/var/lib/postgresql/9.6/main" \
  -v "pg-reports:/reports" \
  -e OLD_PG_VERSION=9.6 \
  -e NEW_PG_VERSION=16 \
  -e EXTENSIONS=postgis \
  --user postgres \
  postgis/postgis:9.6-3.0 \
  bash /init-old-cluster.sh
```

**Step 3 — upgrade and verify** (same as the standard workflow above, but with `--platform linux/amd64`).

---

## Project Layout

```
pg_upgrade/
├── Dockerfile                  # Generic multi-stage build; parameterized via build args
├── scripts/
│   ├── entrypoint.sh           # Dispatches init-old / upgrade / verify; fixes volume ownership
│   ├── init-old-cluster.sh     # Initialises old PG cluster; creates testdb + analytics + fixtures
│   ├── install-extensions.sh   # Called at build time for both old and new PG versions
│   ├── run-upgrade.sh          # Runs pg_upgrade --check then the real upgrade
│   └── verify-new-cluster.sh   # Starts new cluster; runs integrity assertions
└── .github/workflows/
    └── pg-upgrade.yml          # CI: build matrix + test matrix, pushes to GHCR and DockerHub
```

### How the Dockerfile works

The build has two stages:

- **Stage 1 (`old_binaries`)**: starts from the old PG image (or a `postgis/postgis` image for extension paths), installs extension packages, and collects ICU and PostGIS dependency `.so` files into `/tmp/icu-libs` and `/tmp/postgis-ext-libs`.
- **Stage 2 (runtime)**: starts from `postgres:<new>-<distro>`, copies the old PG binaries and extension files from Stage 1, registers the compat libraries via `ldconfig`, and copies all scripts from `scripts/`.

The compat library mechanism allows old PG binaries compiled against one Debian release (e.g. Stretch's `libproj.so.12`) to run on a different release (e.g. Bullseye's runtime which only ships `libproj.so.19`). Versioned SONAMEs ensure the old and new libraries coexist without conflict.

---

## Adding a New Upgrade Path

Edit `.github/workflows/pg-upgrade.yml` and add one entry to each matrix:

```yaml
# In the build-and-push matrix:
- { tag: "14-to-17", from: "14", to: "17", old_distro: "-bookworm", distro: "bookworm" }

# In the test-upgrade matrix:
- { tag: "14-to-17", from: "14", to: "17" }
```

**Field reference:**

| Field | Required | Description |
|---|---|---|
| `tag` | yes | Image tag suffix and job name |
| `from` | yes | Old PG major version |
| `to` | yes | New PG major version |
| `old_distro` | yes | Debian suffix for old image (e.g. `-bookworm`); empty string for EOL versions |
| `distro` | yes | Debian release for runtime image (`bullseye` or `bookworm`) |
| `old_image` | PostGIS only | Full image spec when using a non-standard source image |
| `extensions` | PostGIS only | Comma-separated extensions to install |

**Distro selection guide:**

- PG 9.6, 10, 11: `old_distro: ""` (EOL frozen images), runtime `distro: "bullseye"`
- PG 12–16: `old_distro: "-bookworm"`, runtime `distro: "bookworm"` for 17+ targets; `distro: "bullseye"` for 16 targets
- PG 17+: `old_distro: "-bookworm"`, runtime `distro: "bookworm"`

Test locally before opening a PR (see [Running the Full Upgrade Pipeline Locally](#running-the-full-upgrade-pipeline-locally)).

---

## Adding a New Extension

Extensions are managed in `scripts/install-extensions.sh`. Add a `case` entry in `pkg_for()` that maps the extension name to its Debian package:

```bash
pkg_for() {
  local ext="${1}" ver="${2}"
  case "${ext}" in
    # existing entries ...
    myext) echo "postgresql-${ver}-myext" ;;
    *) echo "Unknown extension: ${ext}" >&2; exit 1 ;;
  esac
}
```

The script is called at build time for both Stage 1 (old PG) and Stage 2 (new PG), so the package name must be valid for all supported PG major versions. If a package is not available for older EOL versions, add a version guard inside the case entry.

For extensions that ship their `.so` files inside a `postgis/postgis`-style pre-built image, add a presence check so the apt install is skipped:

```bash
myext)
  [ -f "/usr/share/postgresql/${ver}/extension/myext.control" ] && return
  echo "postgresql-${ver}-myext" ;;
```

After adding the extension, add a fixture in `scripts/init-old-cluster.sh` (guarded by `has_extension myext`) and assertions in `scripts/verify-new-cluster.sh` (guarded by `has_extension myext`).

---

## Shell Script Conventions

- All scripts use `set -euo pipefail`.
- Required environment variables are declared with `:?` so the script aborts immediately with a clear message if they are unset: `VAR="${VAR:?VAR must be set}"`.
- `has_report()` guards all writes to the markdown report — the `/reports` volume is optional.
- `hr()` prints a 70-character separator line used consistently across all three scripts.
- Comments explain **why**, not what. Do not add comments that restate what the code does.

---

## How CI Works

The CI pipeline (`.github/workflows/pg-upgrade.yml`) has two jobs:

**`build-and-push`** — runs for every push/PR. Builds all matrix images using Docker Buildx with GHA layer caching and pushes to:
- `ghcr.io/<owner>/pg-upgrade:<tag>-<sha>` (used by the test job; avoids DockerHub rate limits)
- `<dockerhub-user>/pg-upgrade:<tag>` and `…:<tag>-<sha>` (public images)

**`test-upgrade`** — runs after `build-and-push`. Pulls the GHCR image by SHA tag and runs the full three-step pipeline (init → upgrade → verify) for every matrix path. Publishes the upgrade report to the GitHub Actions step summary.

Both jobs use `fail-fast: false` so a failure in one path does not cancel the others.

---

## Pull Request Checklist

Before opening a PR, confirm:

- [ ] Tested locally: `init-old` → `upgrade` → `verify` all pass for the affected path(s)
- [ ] `--no-cache` build used when touching `Dockerfile` or `install-extensions.sh`
- [ ] Apple Silicon tested with `--platform linux/amd64` if the path uses an amd64-only source image
- [ ] CI passes on the PR branch
- [ ] Commit messages describe *why*, not just *what*

Open an issue first for larger changes (new extension support, architecture changes) so the approach can be agreed before you invest time writing code.
