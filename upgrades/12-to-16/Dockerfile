# Upgrade path: PostgreSQL 12 → 16
# Standalone build (from repo root):
#   docker build -f upgrades/12-to-16/Dockerfile -t abhsss/pg-upgrade:12-to-16 .

ARG OLD_PG_VERSION=12
ARG NEW_PG_VERSION=16
ARG NEW_PG_DISTRO=bullseye

FROM postgres:${OLD_PG_VERSION} AS old_binaries
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

COPY --from=old_binaries /usr/lib/postgresql/${OLD_PG_VERSION}  /usr/lib/postgresql/${OLD_PG_VERSION}
COPY --from=old_binaries /usr/share/postgresql/${OLD_PG_VERSION} /usr/share/postgresql/${OLD_PG_VERSION}

RUN mkdir -p \
      /var/lib/postgresql/${OLD_PG_VERSION}/main \
      /var/lib/postgresql/${NEW_PG_VERSION}/main \
    && chown -R postgres:postgres /var/lib/postgresql

COPY scripts/ /usr/local/bin/pg-upgrade-scripts/
RUN chmod +x /usr/local/bin/pg-upgrade-scripts/*.sh

ENTRYPOINT ["/usr/local/bin/pg-upgrade-scripts/entrypoint.sh"]
