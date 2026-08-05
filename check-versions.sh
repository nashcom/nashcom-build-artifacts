#!/bin/bash
# Reports the latest published upstream release for curl, openssl, and zlib
# next to what's currently pinned in project/versions.env, and the SHA-256
# of each pinned tarball (downloaded into project/sources/ if not already
# cached -- same cache fetch() uses, so this doesn't duplicate downloads
# build.sh would also need). Purely informational: does not touch
# versions.env, does not build anything. Bump project/versions.env by hand
# (or override per-build with CURL_VERSION=... ./build.sh) to move to a
# newer version.
#
# IMPORTANT: the printed SHA-256 is computed from what THIS script itself
# downloaded -- it is not cross-checked against the project's own
# published checksum (GitHub's release API doesn't expose one). Treat it
# as "avoid retyping a 64-char hex string by hand," not as verification --
# confirm it against the real download page (see project/versions.env's
# comments for the URLs) at least once before pinning it as the value
# fetch() will enforce on every future download.
#
# Uses the GitHub releases API (unauthenticated, ~60 requests/hour/IP) —
# no jq dependency, just curl + sed.
#
# Usage:
#   ./check-versions.sh

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# shellcheck disable=SC1091
source project/versions.env

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

# log_error: always a blank line before and after, so an error stands out
# from whatever was printed before/after it instead of blending in.
log_error()
{
  echo >&2
  echo "Error: $*" >&2
  echo >&2
}

latest_tag()
{
  local repo="$1"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1
}

CURL_LATEST_TAG="$(latest_tag curl/curl)"
CURL_LATEST="${CURL_LATEST_TAG#curl-}"
CURL_LATEST="${CURL_LATEST//_/.}"

OPENSSL_LATEST_TAG="$(latest_tag openssl/openssl)"
OPENSSL_LATEST="${OPENSSL_LATEST_TAG#openssl-}"

ZLIB_LATEST_TAG="$(latest_tag madler/zlib)"
ZLIB_LATEST="${ZLIB_LATEST_TAG#v}"

header "Pinned vs. latest upstream"

printf '%-8s pinned=%-12s latest=%s\n' curl    "${CURL_VERSION}"    "${CURL_LATEST:-unknown}"
printf '%-8s pinned=%-12s latest=%s\n' openssl "${OPENSSL_VERSION}" "${OPENSSL_LATEST:-unknown}"
printf '%-8s pinned=%-12s latest=%s\n' zlib    "${ZLIB_VERSION}"    "${ZLIB_LATEST:-unknown}"

# hash_of <url> <tarball>: reuses project/sources/ as a cache, same as
# project/lib/common.sh's fetch() -- downloading here doesn't cost a
# second download later when build.sh actually runs.
hash_of()
{
  local url="$1" tarball="$2"
  mkdir -p project/sources
  if [ ! -f "project/sources/${tarball}" ]; then
    if ! curl -fsSL -o "project/sources/${tarball}" "${url}"; then
      log_error "Download failed: ${url}"
      return 1
    fi
  fi
  sha256sum "project/sources/${tarball}" | cut -d' ' -f1
}

header "SHA-256 of pinned tarballs (NOT cross-checked -- see the top of this script)"

CURL_TARBALL="curl-${CURL_VERSION}.tar.xz"
OPENSSL_TARBALL="openssl-${OPENSSL_VERSION}.tar.gz"
ZLIB_TARBALL="zlib-${ZLIB_VERSION}.tar.gz"

CURL_HASH="$(hash_of "${CURL_URL}" "${CURL_TARBALL}")"
OPENSSL_HASH="$(hash_of "${OPENSSL_URL}" "${OPENSSL_TARBALL}")"
ZLIB_HASH="$(hash_of "${ZLIB_URL}" "${ZLIB_TARBALL}")"

printf '%-8s %s  (%s)\n' curl    "${CURL_HASH}"    "${CURL_TARBALL}"
printf '%-8s %s  (%s)\n' openssl "${OPENSSL_HASH}" "${OPENSSL_TARBALL}"
printf '%-8s %s  (%s)\n' zlib    "${ZLIB_HASH}"    "${ZLIB_TARBALL}"
