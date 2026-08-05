#!/bin/bash
# Build zlib, both static and shared. Built first: nothing else needs to
# be built before it, and curl's configure step links against it.

set -euo pipefail
source /project/lib/common.sh
source /project/versions.env

MARKER=/depends/zlib/.built-version
if already_built "${MARKER}" "${ZLIB_VERSION}" /depends/zlib/lib/libz.a \
   && already_built "${MARKER}" "${ZLIB_VERSION}" /depends/zlib/lib/libz.so; then
  log "Zlib ${ZLIB_VERSION} already built in /depends/zlib, skipping (set FORCE_REBUILD=1 to force)"
  exit 0
fi

fetch "${ZLIB_URL}" "zlib-${ZLIB_VERSION}.tar.gz" "zlib-${ZLIB_VERSION}" "${ZLIB_SHA256}"
cd "/build/zlib-${ZLIB_VERSION}"

log "Configuring zlib ${ZLIB_VERSION}"
./configure --prefix=/depends/zlib

log "Building zlib ${ZLIB_VERSION}"
make -j"$(nproc)"

log "Installing zlib ${ZLIB_VERSION}"
make install

mark_built "${MARKER}" "${ZLIB_VERSION}"
