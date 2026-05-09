# Generic pg_upgrade image — parameterized via build args.
# Every per-path Dockerfile under upgrades/ delegates here via these args.
# Build directly with:
#   docker build \
#     --build-arg OLD_PG_VERSION=13 \
#     --build-arg NEW_PG_VERSION=16 \
#     -t pg-upgrade:13-to-16 .

ARG OLD_PG_VERSION=9.6
ARG NEW_PG_VERSION=16
# Bullseye carries libssl1.1, required by old-version binaries compiled on
# Stretch or Buster. ICU version mismatches are handled separately below.
ARG NEW_PG_DISTRO=bullseye

# ── Stage 1: source old PostgreSQL binaries ───────────────────────────────
FROM postgres:${OLD_PG_VERSION} AS old_binaries
# Collect ICU shared libraries into a known path so the runtime stage can
# COPY them without hardcoding an arch-specific triplet directory.
RUN mkdir /tmp/icu-libs && \
    find /usr/lib -name 'libicu*.so*' ! -name '*.a' -exec cp {} /tmp/icu-libs/ \;

# ── Stage 2: runtime image ────────────────────────────────────────────────
FROM postgres:${NEW_PG_VERSION}-${NEW_PG_DISTRO}

ARG OLD_PG_VERSION
ARG NEW_PG_VERSION

ENV OLD_PG_VERSION=${OLD_PG_VERSION}
ENV NEW_PG_VERSION=${NEW_PG_VERSION}
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
COPY --from=old_binaries /usr/lib/postgresql/${OLD_PG_VERSION}  /usr/lib/postgresql/${OLD_PG_VERSION}
COPY --from=old_binaries /usr/share/postgresql/${OLD_PG_VERSION} /usr/share/postgresql/${OLD_PG_VERSION}

# Old PG binaries may link against an ICU version absent from the new base image
# (e.g. libicu57 on Stretch, libicu63 on Buster vs libicu67 on Bullseye).
# Place them in an isolated directory — versioned sonames (*.so.57, *.so.67)
# ensure each binary loads only its own version with no conflict.
COPY --from=old_binaries /tmp/icu-libs/ /usr/lib/postgresql/icu-compat/
RUN echo /usr/lib/postgresql/icu-compat > /etc/ld.so.conf.d/pg-icu-compat.conf && ldconfig

RUN mkdir -p \
      /var/lib/postgresql/${OLD_PG_VERSION}/main \
      /var/lib/postgresql/${NEW_PG_VERSION}/main \
    && chown -R postgres:postgres /var/lib/postgresql

COPY scripts/ /usr/local/bin/pg-upgrade-scripts/
RUN chmod +x /usr/local/bin/pg-upgrade-scripts/*.sh

ENTRYPOINT ["/usr/local/bin/pg-upgrade-scripts/entrypoint.sh"]
