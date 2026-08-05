#!/bin/bash
# Build libcurl, both static and shared, linked against our own openssl +
# zlib (not the system ones from openssl-devel/zlib-devel). Built last:
# depends on both.

set -euo pipefail
source /project/lib/common.sh
source /project/versions.env

# marker includes openssl/zlib versions too, not just curl's own -- curl
# links against them at configure time, so a dependency version change
# needs a curl rebuild even if CURL_VERSION itself didn't change.
MARKER=/depends/curl/.built-version
STAMP="${CURL_VERSION}|${OPENSSL_VERSION}|${ZLIB_VERSION}"
LIBCURL_A=/depends/curl/lib/libcurl.a
LIBCURL_SO=/depends/curl/lib/libcurl.so

if already_built "${MARKER}" "${STAMP}" "${LIBCURL_A}" \
   && already_built "${MARKER}" "${STAMP}" "${LIBCURL_SO}"; then
  log "Curl ${CURL_VERSION} (openssl ${OPENSSL_VERSION}, zlib ${ZLIB_VERSION})"
  log "already built in /depends/curl, skipping (set FORCE_REBUILD=1 to force)"
  exit 0
fi

CURL_TARBALL="curl-${CURL_VERSION}.tar.xz"
fetch "${CURL_URL}" "${CURL_TARBALL}" "curl-${CURL_VERSION}" "${CURL_SHA256}"
cd "/build/curl-${CURL_VERSION}"

log "Running autoreconf for curl ${CURL_VERSION}"
autoreconf -fi

log "Configuring curl ${CURL_VERSION}"
./configure \
  --prefix=/depends/curl \
  --enable-shared --enable-static \
  --with-openssl=/depends/openssl \
  --with-zlib=/depends/zlib \
  --without-libpsl \
  --without-nghttp2 \
  --without-libssh2 \
  --without-brotli \
  --without-zstd \
  --without-libidn2 \
  --disable-ldap \
  --disable-rtsp \
  --disable-dict \
  --disable-gopher \
  --disable-imap \
  --disable-mqtt \
  --disable-pop3 \
  --disable-telnet \
  --disable-smtp \
  --disable-tftp \
  --disable-ftp

log "Building curl ${CURL_VERSION}"
make -j"$(nproc)"

log "Installing curl ${CURL_VERSION}"
make install

mark_built "${MARKER}" "${STAMP}"
