# Official PostgreSQL 17.11 / Alpine 3.24.3, resolved for linux/amd64 on 2026-10-26.
FROM postgres@sha256:e4cb93687b062cd25a0e8f672d85a7708235009d70d31f8a7698d9370092a9c4 AS client-rootfs
USER root
RUN set -eu; \
    find /usr/local/bin -maxdepth 1 -type f \
      ! -name psql ! -name pg_dump ! -name pg_restore -delete; \
    rm -rf /docker-entrypoint-initdb.d; \
    addgroup -S -g 65532 pgclient; \
    adduser -S -D -H -u 65532 -G pgclient -s /bin/sh pgclient

# A fresh image configuration avoids inheriting the server's VOLUME, entrypoint,
# exposed port and postgres command. Preserve the OS/package inventory in full.
FROM scratch
COPY --from=client-rootfs / /
ARG SOURCE_COMMIT
LABEL org.opencontainers.image.source="https://github.com/nellesf/nextStop" \
      org.opencontainers.image.revision="${SOURCE_COMMIT}" \
      org.opencontainers.image.version="17.11" \
      org.opencontainers.image.base.digest="sha256:e4cb93687b062cd25a0e8f672d85a7708235009d70d31f8a7698d9370092a9c4" \
      tech.nextstop.image-purpose="postgres-client"
ENV PATH="/usr/local/bin:/usr/bin:/bin" LANG="C.UTF-8" PG_MAJOR="17" PG_VERSION="17.11"
USER 65532:65532
WORKDIR /tmp
RUN set -eu; \
    test "$(id -u):$(id -g)" = '65532:65532'; \
    for tool in psql pg_dump pg_restore; do \
      test "$("$tool" --version)" = "$tool (PostgreSQL) 17.11"; \
    done; \
    test ! -e /usr/local/bin/gosu; \
    test ! -e /usr/local/bin/postgres; \
    test ! -e /usr/local/bin/initdb; \
    test ! -e /usr/local/bin/pg_ctl; \
    test ! -e /usr/local/bin/docker-entrypoint.sh
CMD ["psql", "--version"]
