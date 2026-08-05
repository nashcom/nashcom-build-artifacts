# Shared helpers for the build-*.sh scripts. Sourced, not executed.

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

log()
{
  echo "[$(date -u +%H:%M:%S)] $*"
}

# die: always a blank line before and after, so an error stands out from
# whatever was printed before/after it instead of blending in.
die()
{
  echo >&2
  echo "[$(date -u +%H:%M:%S)] Error: $*" >&2
  echo >&2
  exit 1
}

# fetch <url> <tarball-name> <extracted-dir-name> [expected-sha256]
# Downloads into /project/sources (cached across reruns) and extracts into
# /build/<extracted-dir-name>, skipping work already done. /build is
# host-mounted (./build) and persists after the container exits -- unlike a
# container-local /tmp, so a failed configure/make can actually be
# inspected afterward (config.log, object files, etc.), same spirit as
# ./latest for final artifacts.
#
# If expected-sha256 is given, the tarball is checksummed every time
# (fresh download or cached) and a mismatch aborts the build before
# anything gets extracted/compiled -- catches a corrupted cache entry or a
# tampered/wrong download, not just a failed transfer. If it's empty, a
# WARN is logged instead of failing, so this is opt-in per library via
# versions.env rather than a hard requirement.
fetch()
{
  local url="$1"
  local tarball="$2"
  local extracted_dir="$3"
  local expected_sha256="${4:-}"

  mkdir -p /project/sources /build
  cd /build || die "Cannot cd to /build"

  if [ ! -f "/project/sources/${tarball}" ]; then
    echo
    log "Downloading ${tarball}"
    curl -fLo "/project/sources/${tarball}" "${url}" || die "Download failed: ${url}"
    echo
  else
    log "Using cached /project/sources/${tarball}"
  fi

  if [ -n "${expected_sha256}" ]; then
    local actual_sha256
    actual_sha256="$(sha256sum "/project/sources/${tarball}" | cut -d' ' -f1)"
    if [ "${actual_sha256}" = "${expected_sha256}" ]; then
      log "Checksum OK for ${tarball}"
    else
      die "Checksum mismatch for ${tarball}: expected ${expected_sha256}," \
        "got ${actual_sha256} -- possibly corrupted cache" \
        "(rm /project/sources/${tarball} and retry) or a tampered/wrong download"
    fi
  else
    log "No checksum configured for ${tarball} in versions.env -- skipping verification"
  fi
  echo

  if [ ! -d "${extracted_dir}" ]; then
    log "Extracting ${tarball}"
    tar xf "/project/sources/${tarball}" || die "Extract failed: ${tarball}"
  fi

  if [ ! -d "${extracted_dir}" ]; then
    die "Expected directory ${extracted_dir} not found after extracting ${tarball}"
  fi
}

# already_built <marker-file> <version> <deliverable...>: true if
# <marker-file> exists and records exactly <version> AND at least one of
# the given deliverable paths actually exists -- lets a build-*.sh skip
# straight to exit instead of reconfigure+make+install, so you can iterate
# on e.g. just curl without redoing openssl/zlib every run. The
# deliverable check matters on its own: a marker whose version still
# matches but whose .a got deleted/moved by hand must NOT be trusted, or
# validate-artifacts.sh would fail on a "successful" build. Set
# FORCE_REBUILD=1 to ignore markers and rebuild everything regardless.
already_built()
{
  local marker="$1" version="$2"
  shift 2
  [ "${FORCE_REBUILD:-0}" = "1" ] && return 1
  [ -f "${marker}" ] || return 1
  [ "$(cat "${marker}")" = "${version}" ] || return 1
  for deliverable in "$@"; do
    [ -s "${deliverable}" ] && return 0
  done
  return 1
}

# mark_built <marker-file> <version>: records what already_built checks
# for, written only after a full successful build+install.
mark_built()
{
  local marker="$1" version="$2"
  echo "${version}" > "${marker}"
}
