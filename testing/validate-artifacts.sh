#!/bin/bash
# Validates that a build output directory (staging/, latest/, or a
# versions/<combo>/ snapshot) actually contains both the static AND shared
# libs + headers we expect (zlib/openssl/curl each ship both), and flags
# any shared object turning up somewhere it shouldn't. The CLI tools
# (openssl/curl) and the project/testing/*.cpp test binaries are still
# expected to be static, independent of the libs shipping both forms.
# Logging style matches
# D:\github\pg-guard\docker\test_roundtrip.sh (ts/header/pass/fail/warn/info,
# same colors and RESULTS block) so our test scripts read the same way.
#
# Usage: ./testing/validate-artifacts.sh <dir>
#   e.g. ./testing/validate-artifacts.sh latest
#        ./testing/validate-artifacts.sh staging
#        ./testing/validate-artifacts.sh versions/curl-8.21.0_openssl-4.0.1_zlib-1.3.2
set -uo pipefail

BASE="${1:?usage: validate.sh <dir>}"

PASS=0
FAILURES=0
WARNINGS=0

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

# ANSI colors
CLR_RED="\033[31m"
CLR_GREEN="\033[32m"
CLR_YELLOW="\033[33m"
CLR_BLUE="\033[34m"
CLR_RESET="\033[0m"

pass()
{
  printf "%s [${CLR_GREEN}PASS${CLR_RESET}] %s\n" "$(ts)" "$*"
  PASS=$((PASS + 1))
}

warn()
{
  printf "%s [${CLR_YELLOW}WARN${CLR_RESET}] %s\n" "$(ts)" "$*"
  WARNINGS=$((WARNINGS + 1))
}

fail()
{
  printf "%s [${CLR_RED}FAIL${CLR_RESET}] %s\n" "$(ts)" "$*"
  FAILURES=$((FAILURES + 1))
}

info()
{
  printf "%s [${CLR_BLUE}INFO${CLR_RESET}] %s\n" "$(ts)" "$*"
}

# check_file_any: pass if any of the given candidate paths (relative to
# BASE) exists and is non-empty -- used for openssl's lib vs lib64 install
# location, which varies by how the target's Configure guessed multilib.
check_file_any()
{
  local desc="$1"
  shift
  for candidate in "$@"; do
    if [ -s "${BASE}/${candidate}" ]; then
      pass "$desc ($candidate)"
      return
    fi
  done
  fail "$desc missing: none of [$*] found under ${BASE}"
}

header "Validating artifacts in ${BASE}"

check_file_any "Curl static lib"   "curl/lib/libcurl.a"
check_file_any "Curl shared lib"   "curl/lib/libcurl.so"
check_file_any "Curl header"       "curl/include/curl/curl.h"
check_file_any "Openssl libssl (static)"  "openssl/lib64/libssl.a" "openssl/lib/libssl.a"
check_file_any "Openssl libssl (shared)"  "openssl/lib64/libssl.so" "openssl/lib/libssl.so"
check_file_any "Openssl libcrypto (static)" "openssl/lib64/libcrypto.a" "openssl/lib/libcrypto.a"
check_file_any "Openssl libcrypto (shared)" "openssl/lib64/libcrypto.so" "openssl/lib/libcrypto.so"
check_file_any "Openssl header"    "openssl/include/openssl/ssl.h"
check_file_any "Zlib static lib"   "zlib/lib/libz.a"
check_file_any "Zlib shared lib"   "zlib/lib/libz.so"
check_file_any "Zlib header"       "zlib/include/zlib.h"
check_file_any "Build info"        "BUILD_INFO.txt"

if [ -f "${BASE}/BUILD_INFO.txt" ]; then
  header "Versions in ${BASE}/BUILD_INFO.txt"
  while IFS= read -r line; do
    [ -n "${line}" ] && info "${line}"
  done < "${BASE}/BUILD_INFO.txt"
fi

info "Scanning for unexpected shared objects"
info "(Only libz/libssl/libcrypto/libcurl .so* and openssl's provider modules are expected)"
# openssl/lib*/ossl-modules/*.so (legacy.so, etc.) are provider plugins --
# OpenSSL always builds these as loadable modules regardless of shared/
# static config, so they don't count. libz/libssl/libcrypto/libcurl .so*
# (the real versioned file plus its .so symlink) are the shared libs we
# now expect to sit alongside the .a files -- checked for explicitly above.
# Anything else here (e.g. a shared lib turning up somewhere unexpected)
# is worth a second look.
while IFS= read -r so; do
  warn "Unexpected shared object present: ${so#"${BASE}/"}"
done < <(find "${BASE}" -name '*.so*' \
  -not -path '*/ossl-modules/*' \
  -not -name 'libz.so*' \
  -not -name 'libssl.so*' \
  -not -name 'libcrypto.so*' \
  -not -name 'libcurl.so*' \
  2>/dev/null)

# check_cli: runs a CLI tool that make install dropped alongside the libs
# (openssl/curl ship their own binary, unlike zlib). `--disable-shared`/
# `no-shared` mean it shouldn't need any .so of ours at all, but if it does
# (e.g. a stale build, or a future config change re-enables shared), retry
# once with LD_LIBRARY_PATH pointed at our own lib dirs so we can tell
# "doesn't run at all" apart from "runs, but isn't actually static" --
# the latter matters because these binaries only keep working if that
# LD_LIBRARY_PATH travels with them wherever they're deployed.
check_cli()
{
  local desc="$1" bin="$2"
  shift 2
  local path="${BASE}/${bin}"

  if [ ! -f "${path}" ]; then
    warn "${desc} not found at ${bin} (skipping run check)"
    return
  fi
  # some bind-mount setups (e.g. an NTFS-backed volume seen through a
  # non-WSL shell) don't surface the exec bit reliably even though the
  # file is a perfectly valid ELF binary -- force it rather than trusting
  # a possibly-wrong -x test.
  chmod +x "${path}" 2>/dev/null || true

  local out out_line
  if out="$("${path}" "$@" 2>&1)"; then
    out_line="$(echo "${out}" | head -n1)"
    pass "${desc} runs (${bin} $*): ${out_line}"
    return
  fi

  local libdirs="${BASE}/openssl/lib64:${BASE}/openssl/lib"
  libdirs="${libdirs}:${BASE}/curl/lib:${BASE}/zlib/lib"
  if out="$(LD_LIBRARY_PATH="${libdirs}" "${path}" "$@" 2>&1)"; then
    out_line="$(echo "${out}" | head -n1)"
    warn "${desc} only runs with LD_LIBRARY_PATH set (not fully static?): ${out_line}"
  else
    out_line="$(echo "${out}" | head -n1)"
    fail "${desc} failed to run even with LD_LIBRARY_PATH: ${out_line}"
  fi
}

header "Running CLI tools"

check_cli "Openssl CLI" "openssl/bin/openssl" version
check_cli "Curl CLI"    "curl/bin/curl"       --version

header "Running compiled test binaries"

# project/testing/*.cpp is compiled by project/lib/build-tests.sh into
# ${BASE}/bin -- run each with no args (test_openssl's main() just prints
# version/provider info and returns 0 with no args, no network involved).
# Unlike the CLI tools above, these link -static (a fully static ELF, per
# test_openssl.cpp's own header comment), so no LD_LIBRARY_PATH fallback makes
# sense here -- if one needs it, that's worth a FAIL, not a WARN.
shopt -s nullglob
test_bins=("${BASE}"/bin/*)
shopt -u nullglob

if [ ${#test_bins[@]} -eq 0 ]; then
  warn "No compiled test binaries found under ${BASE}/bin (has project/lib/build-tests.sh run yet?)"
else
  for bin in "${test_bins[@]}"; do
    name="$(basename "${bin}")"

    # bin/ can also hold non-binary helper files a user drops there for
    # manual testing (e.g. cacert.pem, per test_openssl.cpp/test_curl.cpp's
    # CA-bundle lookup) -- skip anything that isn't an actual compiled
    # binary instead of trying to execute it.
    if ! file -b "${bin}" | grep -q "ELF"; then
      warn "${name} is not an ELF binary, skipping (not a compiled test program)"
      continue
    fi

    chmod +x "${bin}" 2>/dev/null || true

    if out="$("${bin}" 2>&1)"; then
      pass "${name} runs: $(echo "${out}" | head -n1)"
    else
      fail "${name} failed to run: $(echo "${out}" | head -n1)"
    fi
  done
fi

header "RESULTS"
printf "Passed  : %3d\n" "$PASS"
printf "Warnings: %3d\n" "$WARNINGS"
printf "Failures: %3d\n" "$FAILURES"
echo

[ "$FAILURES" -eq 0 ]
