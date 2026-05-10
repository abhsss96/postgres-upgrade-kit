# Generic pg_upgrade image — parameterized via build args.
# Every per-path Dockerfile under upgrades/ delegates here via these args.
# Build directly with:
#   docker build \
#     --build-arg OLD_PG_VERSION=13 \
#     --build-arg NEW_PG_VERSION=16 \
#     --build-arg EXTENSIONS=postgis \
#     -t pg-upgrade:13-to-16 .

ARG OLD_PG_VERSION=9.6
ARG NEW_PG_VERSION=16
# Bullseye carries libssl1.1, required by old-version binaries compiled on
# Stretch or Buster. ICU version mismatches are handled separately below.
ARG NEW_PG_DISTRO=bullseye
# Full image spec for the old PG source stage. Active PG versions (12+) must
# be pinned to a specific distro tag (e.g. postgres:13-bookworm) so that their
# binaries are compiled against the same GLIBC as the runtime image. EOL
# versions (9.6, 10, 11) use the untagged image since those are frozen.
ARG OLD_PG_IMAGE=postgres:${OLD_PG_VERSION}
# Comma-separated list of extensions to install, e.g. "postgis" or "postgis,pgvector".
# Empty string (default) installs no extra packages.
ARG EXTENSIONS=""

# ── Stage 1: source old PostgreSQL binaries ───────────────────────────────
FROM ${OLD_PG_IMAGE} AS old_binaries
ARG OLD_PG_VERSION
ARG EXTENSIONS
# Install extension packages so their .so files land in /usr/lib/postgresql/${OLD_PG_VERSION}/lib/
# and control files land in /usr/share/postgresql/${OLD_PG_VERSION}/extension/ — both
# directories are COPYed to the runtime stage below.
COPY scripts/install-extensions.sh /tmp/install-extensions.sh
RUN chmod +x /tmp/install-extensions.sh && \
    /tmp/install-extensions.sh "${OLD_PG_VERSION}" "${EXTENSIONS}"
# Collect ICU shared libraries into a known path so the runtime stage can
# COPY them without hardcoding an arch-specific triplet directory.
RUN mkdir /tmp/icu-libs && \
    find /usr/lib -name 'libicu*.so*' ! -name '*.a' -exec cp {} /tmp/icu-libs/ \;

# Collect PostGIS dependency .so files whose SONAMEs differ between the source
# and runtime distros so the runtime can load old extension binaries:
#   libproj:   .so.12 (Stretch PROJ 4.9)    vs .so.19 (Bullseye PROJ 7.2)
#   libgdal:   .so.20 (Stretch GDAL 2.1)    vs .so.28 (Bullseye GDAL 3.2)
#   libjson-c: .so.3  (Stretch json-c 0.12) vs .so.5  (Bullseye json-c 0.15)
# Search both /usr/lib and /lib — on Stretch some system libs live in /lib
# rather than /usr/lib (pre-usrmerge). On Bullseye+ /lib is a symlink to
# /usr/lib so the double search is harmless.
# libgeos is intentionally excluded: its SONAME (libgeos_c.so.1) is ABI-stable
# across 3.x releases, so the system GEOS on the runtime distro works for old
# PostGIS binaries. Including old libgeos here would shadow the system GEOS via
# ldconfig priority (pg-compat.conf < x86_64-linux-gnu.conf alphabetically),
# causing PostGIS 16 to load an old GEOS that lacks GEOSSymDifferencePrec.
RUN mkdir /tmp/postgis-ext-libs && \
    find /usr/lib /lib -maxdepth 3 \
      \( -name 'libproj*.so*' -o -name 'libgdal*.so*' -o -name 'libjson-c*.so*' \) \
      ! -name '*.a' ! -name '*.la' \
      -exec cp {} /tmp/postgis-ext-libs/ \; 2>/dev/null || true

# ── Stage 2: runtime image ────────────────────────────────────────────────
FROM postgres:${NEW_PG_VERSION}-${NEW_PG_DISTRO}

ARG OLD_PG_VERSION
ARG NEW_PG_VERSION
ARG EXTENSIONS

ENV OLD_PG_VERSION=${OLD_PG_VERSION}
ENV NEW_PG_VERSION=${NEW_PG_VERSION}
ENV EXTENSIONS=${EXTENSIONS}
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

RUN apt-get update && apt-get install -y \
    locales \
    && locale-gen en_US.UTF-8 \
    && update-locale LANG=en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# Copy old PostgreSQL server binaries and catalog data.
# psql is intentionally excluded; all SQL operations use the new PG's psql,
# which is backward-compatible and avoids libreadline ABI mismatches.
# Extension .so files (e.g. postgis-3.so) ride along since they live under
# /usr/lib/postgresql/${OLD_PG_VERSION}/lib/ and /usr/share/postgresql/${OLD_PG_VERSION}/extension/.
COPY --from=old_binaries /usr/lib/postgresql/${OLD_PG_VERSION}  /usr/lib/postgresql/${OLD_PG_VERSION}
COPY --from=old_binaries /usr/share/postgresql/${OLD_PG_VERSION} /usr/share/postgresql/${OLD_PG_VERSION}

# Old PG binaries may link against an ICU version absent from the new base image
# (e.g. libicu57 on Stretch, libicu63 on Buster vs libicu67 on Bullseye).
# Place them in an isolated directory — versioned sonames (*.so.57, *.so.67)
# ensure each binary loads only its own version with no conflict.
COPY --from=old_binaries /tmp/icu-libs/ /usr/lib/postgresql/icu-compat/
COPY --from=old_binaries /tmp/postgis-ext-libs/ /usr/lib/postgresql/postgis-ext-compat/
RUN echo /usr/lib/postgresql/icu-compat        >  /etc/ld.so.conf.d/pg-compat.conf && \
    echo /usr/lib/postgresql/postgis-ext-compat >> /etc/ld.so.conf.d/pg-compat.conf && \
    ldconfig

RUN mkdir -p \
      /var/lib/postgresql/${OLD_PG_VERSION}/main \
      /var/lib/postgresql/${NEW_PG_VERSION}/main \
    && chown -R postgres:postgres /var/lib/postgresql

COPY scripts/ /usr/local/bin/pg-upgrade-scripts/
RUN chmod +x /usr/local/bin/pg-upgrade-scripts/*.sh

# Install extension packages for the new PG version. System libraries pulled
# in here (libgeos, libproj, libgdal for PostGIS, etc.) are the same versions
# as those in Stage 1 because both stages use the same Debian distro — so the
# old extension .so files copied above will resolve their dependencies correctly.
RUN /usr/local/bin/pg-upgrade-scripts/install-extensions.sh "${NEW_PG_VERSION}" "${EXTENSIONS}"

ENTRYPOINT ["/usr/local/bin/pg-upgrade-scripts/entrypoint.sh"]
