# nashcom-build-artifacts

Builds static + shared **openssl**, **libcurl**, and **zlib** in a
`registry.access.redhat.com/ubi9` container — for Domino C-API addins that
need an independent, correctly-linked HTTPS client. Dynamically linking
your own libcurl on Linux silently resolves to Domino's own bundled copy
instead of yours; see [docs/why-static-linking.md](docs/why-static-linking.md)
for the full story.

## Quickstart

```bash
./build.sh
```

Builds curl/openssl/zlib into a staging directory, compiles and runs the
test programs against it, validates the result, and — only if all of that
passes — promotes it to `latest/`. A failed build or test never touches
`latest/`; it's always the most recent build that actually passed.

Nothing lives inside this checkout by default. Three locations, each
independently overridable (CLI flag wins over env var wins over default):

| | env var | `--flag` | default |
|---|---|---|---|
| downloaded tarballs | `SOURCES_DIR` | `--sources-dir=PATH` | `/tmp/nashcom-build-artifacts/sources` |
| in-progress build output | `STAGING_DIR` | `--staging-dir=PATH` | `/tmp/nashcom-build-artifacts/staging` |
| promoted `latest/`+`versions/` | `ARTIFACTS_DIR` | `--artifacts-dir=PATH` | `/local/nashcom-build-artifacts` |

The first two default under `/tmp` deliberately — both fully regenerate
(sources re-download, staging rebuilds), so it's fine if `/tmp` gets cleaned
up between runs. `ARTIFACTS_DIR` is the one thing meant to persist, hence
the separate, non-`/tmp` default.

```bash
./test.sh                                        # recompile + rerun the test programs against latest/, no rebuild
CURL_VERSION=8.20.0 ./build.sh                    # build a specific version (also OPENSSL_VERSION / ZLIB_VERSION)
./build.sh --clean                                # force a genuine from-scratch rebuild
./build.sh --skip-validate                        # build + promote unconditionally, skip testing
./build.sh --sources-dir=/data/sources --staging-dir=/data/staging --artifacts-dir=/data/artifacts
```

Everything you want ends up in `<ARTIFACTS_DIR>/latest/`: headers + `.a`/`.so`
for all three libs, `bin/` (statically-linked test binaries), `BUILD_INFO.txt`,
and the full build/test logs. `<ARTIFACTS_DIR>/versions/` keeps one archived
snapshot per version combo that used to be `latest/`.

The container's build user is a fixed UID/GID (`1000:1000`), not matched to
whoever runs the script — `SOURCES_DIR`/`STAGING_DIR` are host bind mounts
the container writes into directly, so `build.sh` reconciles the two itself:
running as root, it `chown`s them to `1000:1000`; running as `1000:1000`
already, nothing to do; any other user, it falls back to `chmod 777` (the
only option available without `sudo`). One thing this can't fix: if the
checkout itself was cloned as `root`, a non-root user won't be able to write
inside `project/` at all until you `sudo chown -R $(id -u):$(id -g) .` once
— clone as whichever user will actually run `./build.sh` and this never
comes up.

## How it works

Three bind mounts into the ubi9 container, plus one host-only location the
container never touches:

| host | container | contents |
|---|---|---|
| `project/` (this checkout) | `/project` | build/test scripts + sources |
| `SOURCES_DIR` (default `/tmp/...`) | `/sources` | downloaded tarballs, cached across runs |
| `STAGING_DIR` (default `/tmp/...`) | `/depends` | in-progress build output |
| `ARTIFACTS_DIR` (default `/local/...`) | *(never mounted)* | host-only `latest/`, `versions/` |

1. **Build** (ubi9 container) — `build-zlib.sh` -> `build-openssl.sh` ->
   `build-curl.sh`, writing into `STAGING_DIR` (`/depends`); downloads cached
   in `SOURCES_DIR` (`/sources`). `/build`, where sources actually get
   extracted and compiled, is container-local only, never host-mounted.
2. **Test-compile** (ubi9 container) — `build-tests.sh`, also writing into
   `STAGING_DIR`.
3. **Test + promote** (host) — `test.sh` + `validate-artifacts.sh` run
   against `STAGING_DIR`:
   - **pass** — archive the current `latest/` (under its own combo name)
     into `versions/`, then promote staging to become the new `latest/`
   - **fail** — abort; staging is left as-is for inspection

## Layout

```
nashcom-build-artifacts/
├── Dockerfile                  UBI9 + build toolchain (dnf install)
├── build.sh                    host wrapper: build image, build into STAGING_DIR, validate, promote to ARTIFACTS_DIR/latest
├── test.sh                     standalone: compile+run project/testing/*.cpp against any target dir (default ARTIFACTS_DIR/latest)
├── check-versions.sh           reports latest upstream curl/openssl/zlib releases vs. what's pinned (informational only)
├── docs/
│   └── why-static-linking.md   the investigation that motivated this whole pipeline
├── project/                    mounted at /project -- build/test scripts and sources, no artifacts
│   ├── versions.env              pinned default CURL_VERSION / OPENSSL_VERSION / ZLIB_VERSION
│   ├── build.sh                  in-container orchestrator: zlib -> openssl -> curl, writes BUILD_INFO.txt
│   ├── lib/                      build-{zlib,openssl,curl}.sh, common.sh, build-tests.sh
│   └── testing/                  test program sources (e.g. test_openssl.cpp)
├── testing/
│   └── validate-artifacts.sh   host-side: checks .a/.so files + headers, runs CLI tools + bin/* test binaries
└── tools/                      standalone Alpine/musl pipeline -- static openssl/curl CLI binaries, not part of the UBI9 pipeline
    └── build.sh                 builds <ARTIFACTS_DIR>/tools/{openssl,curl} from source on alpine:latest
```

Not part of this checkout — see [Quickstart](#quickstart) for the three
configurable locations:

```
<SOURCES_DIR>/                downloaded tarballs, cached across runs (default /tmp/nashcom-build-artifacts/sources)
<STAGING_DIR>/                mounted at /depends during a build -- untested output, not yet promoted (default /tmp/nashcom-build-artifacts/staging)
<ARTIFACTS_DIR>/               (default /local/nashcom-build-artifacts)
├── latest/                    the promoted, tested build -- always the most recent one that passed
│   └── bin/, openssl/, curl/, zlib/, BUILD_INFO.txt, build.log, test.log
├── versions/                  archive of every build that used to be latest/, keyed by version combo
│   └── curl-8.21.0_openssl-4.0.1_zlib-1.3.2/   same layout as latest/
└── tools/                     tools/build.sh's output: static-pie linked, stripped openssl and curl binaries
```

## Testing

Two layers:

- **`testing/validate-artifacts.sh`** — host-side, checks the expected
  `.a`/`.so` files and headers exist, runs the `openssl`/`curl` CLI tools,
  and runs every binary under `bin/`.
- **`project/testing/*.cpp`** — actual test programs, compiled by
  `project/lib/build-tests.sh` into `bin/`, statically linked so they run
  on any Linux host with no container needed. Both link `-static`, a step
  further than the CLI tools — expect `dlopen`-based OpenSSL providers
  (`legacy`/`fips`) to report `FAILED` there even on a correct build;
  that's an inherent static-linking limitation, not a bug.
  - `test_openssl.cpp` — OpenSSL static-link smoke test: TLS connect, cert
    dump, provider load check.
  - `test_curl.cpp` — libcurl static-link smoke test (the CLI tool check
    above only proves the *dynamically*-linked `curl` binary works; this
    proves `libcurl.a` itself links and runs): prints `curl_version_info()`
    and, with a URL, does a real HTTPS GET.

  For an actual connection (i.e. running either binary with an
  address/URL argument), both resolve their CA trust store via a shared
  `FindCaBundle()` lookup: a local `cacert.pem` first (drop one next to the
  binary to override), then RHEL/UBI9, Debian/Ubuntu, and Alpine's system
  paths in turn — see the top of either `.cpp` file, or
  [docs/why-static-linking.md](docs/why-static-linking.md#ca-certificates)
  for why this can't just be one universal default.

## Incremental builds

`build.sh` skips work at two levels: if `<ARTIFACTS_DIR>/latest/` already is
the exact version combo requested (and still validates), the whole run is a
no-op. Otherwise, each `project/lib/build-*.sh` skips reconfigure/make/install
if `<STAGING_DIR>` already has that exact version built (a `.built-version`
marker next to its output) — handy for iterating on just one library.
`FORCE_REBUILD=1` ignores all of that; `--clean` wipes `<STAGING_DIR>` first.

curl's marker also folds in the openssl/zlib versions it linked against,
so bumping either dependency forces a curl rebuild too.

## Source integrity

`project/versions.env` has an optional `*_SHA256` for each library. If set,
`fetch()` verifies every download (fresh or cached) against it and aborts
on a mismatch; if empty, it just logs a warning. Get the real value from
the project's own download page when you pin a version (URLs are in
`versions.env`'s comments) — `./check-versions.sh` can compute the hash of
what it downloads for convenience, but that's not the same as verifying
against the project's published checksum; cross-check it at least once.

## Standalone static CLI binaries (tools/)

The main pipeline above builds `.a`/`.so` **libraries** matched to Domino's
glibc/UBI9 ABI, for linking into C-API addins — it does not produce a
portable static `openssl`/`curl` **binary** (glibc fights that; see
"Deviations" below). `tools/build.sh` is a separate, simpler pipeline that
does exactly that instead: it builds curl + openssl from source on
`alpine:latest` (musl libc), producing genuinely static, standalone CLI
binaries with no dual static+shared/staging/validate/promote machinery —
just two binaries to look at.

```bash
./tools/build.sh
```

Shares `project/versions.env` for pinned versions/checksums with the main
pipeline (one source of truth), builds into `<ARTIFACTS_DIR>/tools/` (same
configurable, persistent location as the main pipeline's `latest/`, not
inside this checkout), and skips rebuilding a library whose binary already
exists there (`rm <ARTIFACTS_DIR>/tools/curl` to force just that one to
rebuild; `docker volume rm nashcom-alpine-static-work` to force openssl too,
since its install lives in a persistent named volume that curl's build links
against). This container runs as root throughout (`apk add` needs it) and
chowns its own output to `1000:1000` as its last step, so it doesn't leave
root-owned files sitting next to the main pipeline's user-owned `latest/`.

```
tools/build.sh              builds <ARTIFACTS_DIR>/tools/{openssl,curl} from source, statically, on Alpine/musl
<ARTIFACTS_DIR>/tools/      output: static-pie linked, stripped openssl and curl binaries (~8M each)
```

## Deviations from the original build notes

- `build-curl.sh` adds `--with-zlib=/depends/zlib` (the original notes built
  zlib but never pointed curl's configure at it).
- Each library builds **both** static (`.a`) and shared (`.so`) in one
  pass. The `openssl`/`curl` CLI binaries link dynamically as a result
  (each project's default once shared is enabled) — that's out of scope
  here, not a bug to fix. This pipeline's job is the `.a`/`.so`
  **libraries**, matched to Domino's own glibc/UBI9 ABI for linking into
  C-API addins; a genuinely static, portable `openssl`/`curl` **binary**
  is a different problem (glibc fights clean static linking — see the
  `dlopen`/`getaddrinfo`/NSS warnings on `test_openssl.cpp`'s own link) and
  belongs in a separate, Alpine/musl-based pipeline — see
  [Standalone static CLI binaries (tools/)](#standalone-static-cli-binaries-tools)
  above.

## Verification

```bash
ARTIFACTS_DIR="${ARTIFACTS_DIR:-/local/nashcom-build-artifacts}"
file "${ARTIFACTS_DIR}/latest/curl/lib/libcurl.a"
nm "${ARTIFACTS_DIR}/latest/curl/lib/libcurl.a" | grep curl_easy_init
cat "${ARTIFACTS_DIR}/latest/BUILD_INFO.txt"
```
