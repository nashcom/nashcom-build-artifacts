#!/bin/bash
# Build openssl, both static and shared. Built second: curl's configure
# needs it at --with-openssl time.

set -euo pipefail
source /project/lib/common.sh
source /project/versions.env

MARKER=/depends/openssl/.built-version
LIBSSL_A_64=/depends/openssl/lib64/libssl.a
LIBSSL_A_32=/depends/openssl/lib/libssl.a
LIBSSL_SO_64=/depends/openssl/lib64/libssl.so
LIBSSL_SO_32=/depends/openssl/lib/libssl.so

if already_built "${MARKER}" "${OPENSSL_VERSION}" "${LIBSSL_A_64}" "${LIBSSL_A_32}" \
   && already_built "${MARKER}" "${OPENSSL_VERSION}" "${LIBSSL_SO_64}" "${LIBSSL_SO_32}"; then
  log "Openssl ${OPENSSL_VERSION} already built in /depends/openssl, skipping"
  log "(set FORCE_REBUILD=1 to force)"
  exit 0
fi

OPENSSL_TARBALL="openssl-${OPENSSL_VERSION}.tar.gz"
fetch "${OPENSSL_URL}" "${OPENSSL_TARBALL}" "openssl-${OPENSSL_VERSION}" "${OPENSSL_SHA256}"
cd "/build/openssl-${OPENSSL_VERSION}"

log "Configuring openssl ${OPENSSL_VERSION}"
./Configure linux-x86_64 --prefix=/depends/openssl --openssldir=/depends/openssl/ssl no-tests

# Use up to 4 CPU cores for make
if [[ -z "${MAKEFLAGS:-}" ]]; then
  BUILD_JOBS=$(nproc 2>/dev/null || echo 1)
  (( BUILD_JOBS > 4 )) && BUILD_JOBS=4
  export MAKEFLAGS="-j${BUILD_JOBS}"
  log "Parallel Build Jobs: ${BUILD_JOBS}"
fi

log "Building openssl ${OPENSSL_VERSION}"
make

log "Installing openssl ${OPENSSL_VERSION}"
make install

mark_built "${MARKER}" "${OPENSSL_VERSION}"
