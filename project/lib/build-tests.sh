#!/bin/bash
# Compiles every test program under /project/testing/*.cpp against the static
# libs just built into /depends, statically linked (matches the compile
# line documented in test_openssl.cpp's own header comment, adapted from
# /opt/<lib> to /depends/<lib>). Binaries land in /depends/bin, so they end
# up in <ARTIFACTS_DIR>/latest/bin on the host and travel with every
# <ARTIFACTS_DIR>/versions/<combo>/ archive too.

set -euo pipefail
source /project/lib/common.sh

mkdir -p /depends/bin

shopt -s nullglob
sources=(/project/testing/*.cpp)
shopt -u nullglob

if [ ${#sources[@]} -eq 0 ]; then
  log "No test sources under /project/testing, nothing to compile"
  exit 0
fi

for src in "${sources[@]}"; do
  name="$(basename "${src}" .cpp)"
  echo
  log "Compiling ${name}"
  echo
  g++ -o "/depends/bin/${name}" "${src}" \
    -I/depends/openssl/include -I/depends/curl/include -I/depends/zlib/include \
    /depends/curl/lib/libcurl.a \
    /depends/openssl/lib*/libssl.a /depends/openssl/lib*/libcrypto.a \
    /depends/zlib/lib/libz.a \
    -static -ldl -lpthread \
    || die "Compile failed: ${src}"
  echo
done

log "Test binaries built: ${sources[*]/#\/project\/testing\//}"
