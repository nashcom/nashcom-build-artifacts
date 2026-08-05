#!/bin/bash
# Standalone: compiles project/testing/*.cpp (via project/lib/build-tests.sh,
# run in the same image build.sh builds) against whatever's already in the
# target directory, then runs each resulting binary directly on the host --
# they're statically linked, so no container is needed to execute them
# (Linux hosts only). Doesn't rebuild the libs, doesn't run
# testing/validate-artifacts.sh -- just the compile+run step, for quick
# iteration on project/testing/*.cpp itself.
#
# Usage:
#   ./test.sh                 # compile project/testing/*.cpp against ./latest and run each binary
#   ./test.sh staging         # same, but against ./staging (used by build.sh pre-promotion)
#   ./test.sh --no-run        # compile only, don't run (used by build.sh, which leaves
#                                running them to testing/validate-artifacts.sh)

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

IMAGE="nashcom-build-artifacts:latest"
CONTAINER_NAME="nashcom-build-artifacts-tests"
RUN=1
TARGET="latest"

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
    --no-run) RUN=0 ;;
    -*) log_error "Unknown option: ${arg}"; exit 1 ;;
    *) TARGET="${arg}" ;;
  esac
done

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  log_error "Image ${IMAGE} not found -- run ./build.sh first"
  exit 1
fi
if [ ! -f "${TARGET}/BUILD_INFO.txt" ]; then
  log_error "${TARGET}/BUILD_INFO.txt missing -- run ./build.sh first"
  exit 1
fi

header "Compiling test programs (project/testing/*.cpp -> ${TARGET}/bin)"
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker run --rm --name "${CONTAINER_NAME}" \
  -v "$(pwd)/project:/project" \
  -v "$(pwd)/${TARGET}:/depends" \
  --tmpfs "/tmp:uid=1000,gid=1000,exec,mode=1777" \
  "${IMAGE}" /project/lib/build-tests.sh

if [ "${RUN}" -eq 0 ]; then
  exit 0
fi

if [ "$(uname -s)" != "Linux" ]; then
  echo "Skipping test binary execution (host is not Linux; run them under WSL/Linux instead)"
  exit 0
fi

header "Running test binaries (statically linked, run directly on host)"
shopt -s nullglob
bins=("${TARGET}"/bin/*)
shopt -u nullglob

if [ ${#bins[@]} -eq 0 ]; then
  echo "No test binaries found under ${TARGET}/bin"
  exit 0
fi

for bin in "${bins[@]}"; do
  [ -f "${bin}" ] || continue

  # bin/ can also hold non-binary helper files a user drops there for
  # manual testing (e.g. cacert.pem, per test_openssl.cpp/test_curl.cpp's
  # CA-bundle lookup) -- skip anything that isn't an actual compiled
  # binary instead of trying to execute it.
  if ! file -b "${bin}" | grep -q "ELF"; then
    echo "--- ${bin} (skipped, not an ELF binary) ---"
    continue
  fi

  chmod +x "${bin}" 2>/dev/null || true
  echo "--- ${bin} ---"
  "${bin}" || echo "Warning: ${bin} exited non-zero"
done
