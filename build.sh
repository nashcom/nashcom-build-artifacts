#!/bin/bash
# Host-side wrapper: builds the nashcom-build-artifacts image, then builds
# curl/openssl/zlib into ${STAGING_DIR} (never directly into ${ARTIFACTS_DIR}/
# latest). Unless --skip-validate, compiles+runs project/testing/*.cpp and
# runs testing/validate-artifacts.sh against ${STAGING_DIR} *before* anything
# is promoted -- a failing build/test aborts here (set -e), leaving latest/
# untouched and ${STAGING_DIR} around for inspection.
#
# Only once staging is known-good does it get promoted: whatever latest/
# currently is gets archived into ${ARTIFACTS_DIR}/versions/<its-own-combo>/
# (using ITS BUILD_INFO.txt, not the new one), then staging is renamed to
# latest/. versions/ therefore only ever holds builds that used to be
# latest, not a duplicate of the current one.
#
# Sources (downloaded tarballs), staging (in-progress build output), and
# the promoted latest/versions live in three independently configurable
# locations -- not inside this repo checkout at all by default:
#   SOURCES_DIR    (--sources-dir=PATH)    default: /tmp/nashcom-build-artifacts/sources
#   STAGING_DIR    (--staging-dir=PATH)    default: /tmp/nashcom-build-artifacts/staging
#   ARTIFACTS_DIR  (--artifacts-dir=PATH)  default: /local/nashcom-build-artifacts
# CLI flag wins over env var wins over default. SOURCES_DIR/STAGING_DIR
# default under /tmp deliberately -- both are fully regenerable (sources
# re-download, staging rebuilds), so it's fine if /tmp gets cleaned up
# between runs. ARTIFACTS_DIR is the one thing meant to persist, hence the
# separate, non-/tmp default.
#
# The container's build user is a fixed UID/GID (1000:1000, set in the
# Dockerfile) -- not matched to whoever runs this script. Since SOURCES_DIR
# and STAGING_DIR are host bind mounts the container writes into directly,
# ensure_dir_writable_by_container() below reconciles the two: if we're
# root, chown the dir to 1000:1000; if we already *are* 1000:1000, nothing
# to do; otherwise (some other non-root user) the only thing a script can
# do without sudo is chmod 777. ARTIFACTS_DIR doesn't need any of this --
# the container never mounts it, only this script's own mv/rm on the host
# side ever touches it.
#
# The container's /build -- where sources get extracted and actually
# compiled (project/lib/common.sh's fetch()) -- is NOT mounted from the
# host at all: it's a --tmpfs (RAM-backed), gone when the container is
# removed. That step creates/writes thousands of small files (object
# files, per-algorithm generated assembly), and a bind mount to a
# Windows-drive path bridged through WSL2 made that dramatically slower
# -- to the point of looking hung; tmpfs makes it about as fast as that
# workload can go. The trade-off: a failed build's config.log doesn't
# survive the container's removal, and extracted sources don't persist
# across separate ./build.sh invocations -- but staging's .built-version
# markers already skip a fully-built lib before fetch() is ever called,
# which covers the main "don't redo work" case. STAGING_DIR (mounted at
# /depends) stays a host bind mount: make install only writes a few dozen
# headers/.a files there, not a bottleneck.
#
# Not to be confused with project/build.sh, which is the in-container
# orchestrator this script invokes (zlib -> openssl -> curl).
#
# build.sh is incremental at two levels:
#  - if latest/ already IS the exact version combo being requested (and
#    still passes validation), the whole run is a no-op -- nothing to
#    build, nothing to copy, done immediately.
#  - otherwise, each build-*.sh in project/lib skips straight through (no
#    reconfigure/make/install) if staging already has that exact version
#    built (a .built-version marker next to each lib's output) -- handy
#    for iterating on e.g. just curl without redoing openssl/zlib every
#    run, or resuming an interrupted run of the same version combo.
# FORCE_REBUILD=1 ignores all of the above; --clean wipes staging first
# for a truly from-scratch build.
#
# Usage:
#   ./build.sh                       # build (incrementally), test, validate, promote
#   CURL_VERSION=8.20.0 ./build.sh       # override one or more versions
#   FORCE_REBUILD=1 ./build.sh       # ignore staging's version markers, rebuild everything
#   ./build.sh --clean               # wipe staging first, for a from-scratch build
#   ./build.sh --rebuild             # force rebuilding the image (e.g. after editing the Dockerfile)
#   ./build.sh --skip-validate       # skip test-compile/validate and promote unconditionally
#   ./build.sh --validate            # just run testing/validate-artifacts.sh against latest/ and exit
#   ./build.sh --sources-dir=/data/sources --staging-dir=/data/staging --artifacts-dir=/data/artifacts

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Docker-compatible manifest format for podman/buildah -- without this,
# builds default to OCI format, which has led to a much shorter build-cache
# validity window in practice.
export BUILDAH_FORMAT=docker
# Use the longer output format
export BUILDKIT_PROGRESS=plain

IMAGE="nashcom-build-artifacts:latest"
CONTAINER_NAME="nashcom-build-artifacts"
SOURCES_DIR="${SOURCES_DIR:-/tmp/nashcom-build-artifacts/sources}"
STAGING_DIR="${STAGING_DIR:-/tmp/nashcom-build-artifacts/staging}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-/local/nashcom-build-artifacts}"
REBUILD=0
SKIP_VALIDATE=0
CLEAN=0
VALIDATE_ONLY=0

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

for arg in "$@"; do
  case "${arg}" in
    --rebuild) REBUILD=1 ;;
    --skip-validate) SKIP_VALIDATE=1 ;;
    --clean) CLEAN=1 ;;
    --validate) VALIDATE_ONLY=1 ;;
    --sources-dir=*) SOURCES_DIR="${arg#*=}" ;;
    --staging-dir=*) STAGING_DIR="${arg#*=}" ;;
    --artifacts-dir=*) ARTIFACTS_DIR="${arg#*=}" ;;
    *) log_error "Unknown option: ${arg}"; exit 1 ;;
  esac
done

LATEST="${ARTIFACTS_DIR}/latest"
VERSIONS_DIR="${ARTIFACTS_DIR}/versions"

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

# build_info_get <file> <key>: reads one KEY=VALUE out of a BUILD_INFO.txt
# without sourcing it -- staging's and latest's BUILD_INFO.txt both use
# the same variable names (CURL_VERSION etc.), so sourcing both in the
# same shell would clobber one with the other.
build_info_get()
{
  local file="$1" key="$2"
  grep "^${key}=" "${file}" | head -n1 | cut -d= -f2- | tr -d '"'
}

combo_of()
{
  local file="$1"
  local c o z
  c="$(build_info_get "${file}" CURL_VERSION)"
  o="$(build_info_get "${file}" OPENSSL_VERSION)"
  z="$(build_info_get "${file}" ZLIB_VERSION)"
  echo "curl-${c}_openssl-${o}_zlib-${z}"
}

# ensure_dir_writable_by_container <dir>: creates <dir> if missing, and
# makes sure the container's fixed UID 1000 build user can write into it --
# see the header comment for why this three-way split is the complete set
# of options a script has without prompting for sudo. Also used for
# ARTIFACTS_DIR/VERSIONS_DIR below, which the container never actually
# mounts -- same 1000:1000 convention applied for consistency regardless of
# whether this script itself happens to be run as root.
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

# own_by_container_if_root <file>: build.log/test.log are written by `tee`
# running host-side (piped from docker run), not inside the container --
# unlike everything else under STAGING_DIR, their ownership comes from
# whoever runs this script, not from the container's fixed UID 1000. A
# non-root/non-1000 host user's own tee output is already correctly
# theirs; this only needs to act when this script itself is root.
own_by_container_if_root()
{
  [ "$(id -u)" = "0" ] && chown 1000:1000 "$1"
  return 0
}

if [ "${VALIDATE_ONLY}" -eq 1 ]; then
  header "Validating ${LATEST}/"
  bash testing/validate-artifacts.sh "${LATEST}"
  exit $?
fi

ensure_dir_writable_by_container "${SOURCES_DIR}"
ensure_dir_writable_by_container "${STAGING_DIR}"
# ARTIFACTS_DIR/VERSIONS_DIR are never container-mounted, but this script
# itself might be run as root -- a plain mkdir -p would then leave them
# root-owned with no fixup, inconsistent with everything else this script
# manages. Same helper, same 1000:1000 convention, for consistency; latest/'s
# own contents get their ownership from the STAGING_DIR mv, not from here.
ensure_dir_writable_by_container "${ARTIFACTS_DIR}"
ensure_dir_writable_by_container "${VERSIONS_DIR}"

header "Docker image"

if [ "${REBUILD}" -eq 1 ] || ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "Building ${IMAGE}"
  docker build -t "${IMAGE}" .
else
  echo "Image ${IMAGE} already exists, skipping build (use --rebuild to force)"
fi

# If latest/ already IS the exact version combo being requested (and still
# passes validation), there's nothing to do at all -- no build, no copy.
# staging never gets seeded from latest/: once a version is promoted, it
# stays promoted, and copying it back into staging (even just to satisfy
# already_built() markers) is both pointless and, across a bind-mounted
# host directory, needlessly slow.
# shellcheck disable=SC1091
source project/versions.env
WANT_COMBO="curl-${CURL_VERSION}_openssl-${OPENSSL_VERSION}_zlib-${ZLIB_VERSION}"

if [ "${CLEAN}" -ne 1 ] \
   && [ "${FORCE_REBUILD:-0}" != "1" ] \
   && [ -f "${LATEST}/BUILD_INFO.txt" ]; then
  CUR_COMBO="$(combo_of "${LATEST}/BUILD_INFO.txt")"
  if [ "${CUR_COMBO}" = "${WANT_COMBO}" ] \
     && bash testing/validate-artifacts.sh "${LATEST}" >/dev/null 2>&1; then
    header "Already up to date: ${LATEST}/ is ${WANT_COMBO} and passes validation"
    echo "(Bump a version, or use --clean / FORCE_REBUILD=1, to rebuild anyway)"
    print_runtime
    exit 0
  fi
fi

if [ "${CLEAN}" -eq 1 ]; then
  echo "Wiping ${STAGING_DIR}/ for a from-scratch build (--clean)"
  rm -rf "${STAGING_DIR:?}"/* "${STAGING_DIR}"/.[!.]* 2>/dev/null || true
fi

header "Building into ${STAGING_DIR}/ (incrementally unless --clean)"

BUILD_LOG="${STAGING_DIR}/build.log"
echo "Log: ${BUILD_LOG}"
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker run --rm --name "${CONTAINER_NAME}" \
  -v "$(pwd)/project:/project" \
  -v "${SOURCES_DIR}:/sources" \
  -v "${STAGING_DIR}:/depends" \
  --tmpfs "/build:uid=1000,gid=1000,exec" \
  --tmpfs "/tmp:uid=1000,gid=1000,exec,mode=1777" \
  -e CURL_VERSION -e OPENSSL_VERSION -e ZLIB_VERSION -e FORCE_REBUILD \
  "${IMAGE}" /project/build.sh 2>&1 | tee "${BUILD_LOG}"
own_by_container_if_root "${BUILD_LOG}"

STAGING_BUILD_INFO="${STAGING_DIR}/BUILD_INFO.txt"
if [ ! -f "${STAGING_BUILD_INFO}" ]; then
  log_error "${STAGING_BUILD_INFO} missing after build"
  exit 1
fi

header "Testing"

if [ "${SKIP_VALIDATE}" -eq 1 ]; then
  echo "Skipping test-compile/validate, promoting unconditionally (--skip-validate)"
else
  TEST_LOG="${STAGING_DIR}/test.log"
  echo "Log: ${TEST_LOG}"
  ./test.sh --no-run "${STAGING_DIR}" 2>&1 | tee "${TEST_LOG}"

  echo "Validating ${STAGING_DIR}/ before promoting it to ${LATEST}/"
  bash testing/validate-artifacts.sh "${STAGING_DIR}" 2>&1 | tee -a "${TEST_LOG}"
  own_by_container_if_root "${TEST_LOG}"
fi

header "Promoting"

NEW_COMBO="$(combo_of "${STAGING_BUILD_INFO}")"

if [ -f "${LATEST}/BUILD_INFO.txt" ]; then
  OLD_COMBO="$(combo_of "${LATEST}/BUILD_INFO.txt")"
  echo "Archiving current ${LATEST}/ (${OLD_COMBO}) to ${VERSIONS_DIR}/${OLD_COMBO}"
  rm -rf "${VERSIONS_DIR}/${OLD_COMBO}"
  mv "${LATEST}" "${VERSIONS_DIR}/${OLD_COMBO}"
else
  rm -rf "${LATEST}"
fi

echo "Promoting ${STAGING_DIR}/ (${NEW_COMBO}) to ${LATEST}/"
mv "${STAGING_DIR}" "${LATEST}"

header "Done: ${LATEST}/ is now ${NEW_COMBO}, ${VERSIONS_DIR}/ holds every combo it superseded"
print_runtime
