#!/bin/bash
# Builds fully static openssl + curl CLI binaries from source, on Alpine
# (musl libc) instead of UBI9 (glibc). musl makes real static linking
# clean -- no dlopen/getaddrinfo/NSS warnings like the glibc build in
# ../project/lib -- so this is the right tool for a genuinely portable
# static binary. These are standalone utilities, not for linking into
# Domino addins (that stays in the UBI9 pipeline, matched to Domino's own
# glibc/RHEL ABI).
#
# Alpine's own curl-static/openssl-libs-static packages turned out to be
# library-only (no CLI binary included), so this builds curl and openssl
# from source same as the UBI9 pipeline does -- just against musl, and
# without the dual static+shared/staging/validate/promote machinery,
# since the only thing wanted here is two static binaries to look at.
#
# Shares ../project/versions.env for versions/URLs/checksums rather than
# pinning its own separate copy -- one source of truth for what curl/
# openssl version and checksum are trusted, whether built for UBI9 or
# here. zlib isn't built from source here (apk's zlib-dev/zlib-static
# covers it, so ZLIB_* from versions.env is unused).
#
# Output goes to <ARTIFACTS_DIR>/tools/ -- the same configurable, persistent
# location build.sh promotes latest/versions into (see build.sh's own header
# comment), not into this repo checkout. ARTIFACTS_DIR defaults to
# /local/nashcom-build-artifacts, same as build.sh, and is overridable the
# same way (env var or --artifacts-dir=PATH).
#
# openssl's install (/usr/local inside the container) lives in a
# persistent named volume, not the container's own ephemeral layer --
# curl's build needs those .a libs/headers to link against, so if it's
# ephemeral, skipping a rebuild of openssl (because <ARTIFACTS_DIR>/tools/
# openssl already exists) would leave curl with nothing to link against in
# a fresh container. With a persistent volume, openssl only rebuilds if
# /usr/local/bin/openssl isn't already there, and curl only rebuilds if
# <ARTIFACTS_DIR>/tools/curl isn't already there -- e.g. `rm
# <ARTIFACTS_DIR>/tools/curl` and rerun to redo just curl. Force a full
# rebuild of openssl too with `docker volume rm nashcom-alpine-static-work`.
#
# This container runs as root throughout (apk add needs it) -- unlike the
# UBI9 Dockerfile's fixed non-root build user, there's no separate image
# build step here to install packages as root and then drop privileges
# for. To avoid leaving root-owned files under ARTIFACTS_DIR (which would
# otherwise sit right next to build.sh's user-owned latest/versions/, a
# "mixed owners" mess), the container chowns its own output to 1000:1000
# as its last step -- same convention build.sh's ensure_dir_writable_by_
# container() uses for SOURCES_DIR/STAGING_DIR.
#
# Usage:
#   ./tools/build.sh
#   CURL_VERSION=8.20.0 OPENSSL_VERSION=4.0.1 ./tools/build.sh
#   ./tools/build.sh --artifacts-dir=/data/artifacts

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# shellcheck disable=SC1091
source ../project/versions.env

ARTIFACTS_DIR="${ARTIFACTS_DIR:-/local/nashcom-build-artifacts}"

for arg in "$@"; do
  case "${arg}" in
    --artifacts-dir=*) ARTIFACTS_DIR="${arg#*=}" ;;
    *) echo "Error: Unknown option: ${arg}" >&2; exit 1 ;;
  esac
done

TOOLS_DIR="${ARTIFACTS_DIR}/tools"

IMAGE="alpine:latest"
CONTAINER_NAME="nashcom-alpine-static-build"
VOLUME_NAME="nashcom-alpine-static-work"

delim() { echo "--------------------------------------------------------------------------------"; }

# ts: UTC timestamp on every line this script writes, same format as
# pg-guard's own logs (log.go) -- makes it straightforward to correlate a
# line here with the same moment in "docker compose logs".
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

header()
{
  echo
  delim
  echo "$(ts) $*"
  delim
  echo
}

print_runtime()
{
  hours=$((SECONDS / 3600))
  seconds=$((SECONDS % 3600))
  minutes=$((seconds / 60))
  seconds=$((seconds % 60))
  h=""; m=""; s=""
  if [ ! $hours = "1" ] ; then h="s"; fi
  if [ ! $minutes = "1" ] ; then m="s"; fi
  if [ ! $seconds = "1" ] ; then s="s"; fi
  echo
  if [ ! $hours = 0 ]; then
    echo "Completed in $hours hour$h, $minutes minute$m and $seconds second$s"
  elif [ ! $minutes = 0 ]; then
    echo "Completed in $minutes minute$m and $seconds second$s"
  else
    echo "Completed in $seconds second$s"
  fi
  echo
}

# ensure_dir_writable_by_container <dir>: same three-way split as build.sh's
# helper of the same name -- root chowns to 1000:1000, already-1000:1000
# needs nothing, anyone else falls back to chmod 777 (the only option
# without sudo). Duplicated rather than shared since build.sh and this
# script have always kept their own independent copies of delim/ts/header
# etc. too -- no shared host-side lib between them.
ensure_dir_writable_by_container()
{
  local dir="$1"
  local my_uid
  my_uid="$(id -u)"

  mkdir -p "${dir}"

  if [ "${my_uid}" = "0" ]; then
    chown 1000:1000 "${dir}"
  elif [ "${my_uid}" = "1000" ]; then
    : # already the right owner
  else
    chmod 777 "${dir}"
  fi
}

# Fix ARTIFACTS_DIR itself too, not just TOOLS_DIR underneath it -- if this
# script runs before build.sh ever has on a fresh machine, mkdir -p below
# would otherwise silently create the parent as a root-owned side effect
# that never gets chowned (the chown only touches the leaf directory).
ensure_dir_writable_by_container "${ARTIFACTS_DIR}"
ensure_dir_writable_by_container "${TOOLS_DIR}"
docker volume create "${VOLUME_NAME}" >/dev/null

header "Building curl ${CURL_VERSION} + openssl ${OPENSSL_VERSION}, statically, on alpine"
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker run --rm --name "${CONTAINER_NAME}" \
  -v "${TOOLS_DIR}:/out" \
  -v "${VOLUME_NAME}:/usr/local" \
  --tmpfs "/tmp:uid=0,gid=0,exec,mode=1777" \
  -e CURL_VERSION="${CURL_VERSION}" \
  -e OPENSSL_VERSION="${OPENSSL_VERSION}" \
  -e CURL_URL="${CURL_URL}" \
  -e OPENSSL_URL="${OPENSSL_URL}" \
  -e CURL_SHA256="${CURL_SHA256}" \
  -e OPENSSL_SHA256="${OPENSSL_SHA256}" \
  -e CONTAINER_NAME="${CONTAINER_NAME}" \
  "${IMAGE}" sh -c '
# Everything real lives in main(), called below as "if main; then ... else
# ...". set -e inside main() still aborts main() at the first failing
# command (skipping the rest of it), but -e is suspended for main() itself
# here because it is the direct condition of an if -- that is a standard
# POSIX carve-out, so a failure inside main() does not also kill this
# outer script. That is what lets the else branch run instead of the
# container just exiting.
main()
{
set -e
apk update
apk add --no-cache \
  build-base perl linux-headers \
  zlib-dev zlib-static \
  curl autoconf automake libtool \
  libidn2-dev libidn2-static \
  libunistring-dev libunistring-static

# Same delim/ts/header/log_error convention as build.sh, just POSIX sh
# (not bash) since this runs under Alpine busybox sh via `sh -c`.
delim() { echo "--------------------------------------------------------------------------------"; }
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
header()
{
  echo
  delim
  echo "$(ts) $*"
  delim
  echo
}
log_error()
{
  echo >&2
  echo "Error: $*" >&2
  echo >&2
}

# verify_checksum <file> <expected>: same logic as ../project/lib/common.sh
# fetch(), just inline -- this runs under Alpine busybox sh, not bash, so
# sourcing common.sh directly is not assumed portable across shells.
verify_checksum()
{
  file="$1"; expected="$2"
  if [ -z "${expected}" ]; then
    echo "No checksum configured for ${file} in versions.env -- skipping verification"
    return 0
  fi
  actual="$(sha256sum "${file}" | cut -d" " -f1)"
  if [ "${actual}" != "${expected}" ]; then
    log_error "Checksum mismatch for ${file}: expected ${expected}, got ${actual}"
    exit 1
  fi
  echo "Checksum OK for ${file}"
}

if [ -x /usr/local/bin/openssl ]; then
  header "Openssl already built in the persistent volume, skipping"
  echo "(docker volume rm nashcom-alpine-static-work to force a rebuild)"
else
  header "Building openssl ${OPENSSL_VERSION}"
  curl -fLo /tmp/openssl.tar.gz "${OPENSSL_URL}"
  echo
  verify_checksum /tmp/openssl.tar.gz "${OPENSSL_SHA256}"
  echo
  cd /tmp && tar xf openssl.tar.gz && cd "openssl-${OPENSSL_VERSION}"
  ./Configure linux-x86_64 --prefix=/usr/local no-shared no-tests -static
  make -j"$(nproc)"
  make install_sw install_ssldirs
fi
cp /usr/local/bin/openssl /out/openssl
strip /out/openssl
chown 1000:1000 /out/openssl

if [ -f /out/curl ]; then
  header "Curl already built (ARTIFACTS_DIR/tools/curl exists), skipping"
  echo "(rm it from ARTIFACTS_DIR/tools/ to force a rebuild)"
else
  header "Building curl ${CURL_VERSION}"
  curl -fLo /tmp/curl.tar.xz "${CURL_URL}"
  echo
  verify_checksum /tmp/curl.tar.xz "${CURL_SHA256}"
  echo
  cd /tmp && tar xf curl.tar.xz && cd "curl-${CURL_VERSION}"
  autoreconf -fi
  # LIBS=-lunistring: curl detects libidn2 via pkg-config, but without
  # --static that only returns the dynamic "Libs:" field from idn2.pc, not
  # "Requires.private: libunistring" -- so the symbols libidn2.a needs from
  # libunistring never get onto the link line even though the package is
  # installed. Appending it via LIBS puts it at the end of the link
  # command, where a single-pass linker needs it to resolve the pending
  # undefined references coming from libidn2.a.
  LIBS="-lunistring" ./configure \
    --disable-shared --enable-static \
    --with-openssl=/usr/local \
    --with-zlib \
    --without-libpsl \
    --without-nghttp2 \
    --without-libssh2 \
    --without-brotli \
    --without-zstd \
    --disable-ldap \
    --disable-rtsp \
    --disable-dict \
    --disable-gopher \
    --disable-imap \
    --disable-mqtt \
    --disable-pop3 \
    --disable-telnet
  make LDFLAGS="-all-static" -j"$(nproc)"
  cp src/curl /out/curl
fi
strip /out/curl
chown 1000:1000 /out/curl
}

if main; then
  exit 0
fi

echo
echo "Error: build failed."
echo "Container ${CONTAINER_NAME} is staying up so you can look into it -- from another terminal:"
echo
echo "  docker exec -it ${CONTAINER_NAME} sh"
echo
echo "e.g. cd /tmp/curl-*, retry ./configure or make by hand, apk add whatever"
echo "turns out to be missing. Ctrl-C this window when done to stop and remove it."
echo
sleep infinity
'

header "Done: ${TOOLS_DIR}/openssl, ${TOOLS_DIR}/curl"
file "${TOOLS_DIR}/openssl" "${TOOLS_DIR}/curl" 2>/dev/null || true

echo
if [ "$(uname -s)" = "Linux" ]; then
  chmod +x "${TOOLS_DIR}/openssl" "${TOOLS_DIR}/curl" 2>/dev/null || true
  "${TOOLS_DIR}/openssl" version || echo "Warning: ${TOOLS_DIR}/openssl version failed"
  "${TOOLS_DIR}/curl" --version | head -n1 || echo "Warning: ${TOOLS_DIR}/curl --version failed"
else
  echo "Skipping version check (host is not Linux; run them under WSL/Linux instead)"
fi

print_runtime
