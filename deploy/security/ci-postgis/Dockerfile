# Ephemeral GitHub integration database only. The source and both patches are
# pinned independently from the upstream PostgreSQL 17.11/PostGIS 3.6.4 image.
FROM postgis/postgis@sha256:c3d12aa7443aa24999288f67ef59c12f7527aef6517a900fb6cccb1b5071ef43 AS base

FROM base AS build
RUN apk add --no-cache autoconf automake build-base gettext-dev git libtool perl \
    geos-dev proj-dev libxml2-dev json-c-dev protobuf-c-dev $DOCKER_PG_LLVM_DEPS
WORKDIR /build
RUN wget -qO source.tar.gz https://github.com/postgis/postgis/archive/refs/tags/3.6.4.tar.gz \
 && wget -qO prerequisite.patch https://github.com/postgis/postgis/commit/86bf6bf1965bc03b53a391da5a17f1ff134f1fd2.patch \
 && wget -qO decoder.patch https://github.com/postgis/postgis/commit/53e273faeb440176eee83f76319b48afb0b86834.patch \
 && printf '%s\n' \
    '4f80e1a4d227f088ae818f79180debd5894c075615823e0f556f73479cf1f200  source.tar.gz' \
    'bfc54ad35b87f67beca3fe2550421648bb9a6395189c976c067994ca3adf4427  prerequisite.patch' \
    '672dffdd53ba0b1757696af36be964ca777c1f1bdf2b12a428388cd8720454fd  decoder.patch' | sha256sum -c - \
 && tar xzf source.tar.gz --strip-components=1 \
 && git apply --include='postgis/*' prerequisite.patch \
 && git apply --include='postgis/*' --include='deps/flatgeobuf/*' decoder.patch \
 && gettextize --force --copy && ./autogen.sh \
 && ./configure --without-raster --without-address-standardizer --without-topology --without-sfcgal \
 && make -C postgis -j4 \
 && make -C postgis install DESTDIR=/stage \
 && test -s /stage/usr/local/lib/postgresql/postgis-3.so \
 && test -s /stage/usr/local/lib/postgresql/bitcode/postgis-3.index.bc

FROM base
# Docker starts the database as postgres, so the root-only helper is unnecessary.
RUN rm /usr/local/bin/gosu
COPY --from=build /stage/usr/local/lib/postgresql/ /usr/local/lib/postgresql/
USER postgres
ENV PGDATA=/tmp/nextstop-ci-pgdata
LABEL tech.nextstop.image-purpose=ci-postgis
