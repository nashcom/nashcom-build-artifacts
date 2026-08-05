# tools/

Standalone pipeline: builds static, stripped `openssl` + `curl` CLI binaries
from source on Alpine (musl libc) — not part of the main UBI9 pipeline, and
not for linking into Domino addins. See the main
[README](../README.md#standalone-static-cli-binaries-tools) for details.

```bash
./build.sh
```

Output: `<ARTIFACTS_DIR>/tools/openssl`, `<ARTIFACTS_DIR>/tools/curl` — not
inside this checkout. `ARTIFACTS_DIR` defaults to
`/local/nashcom-build-artifacts`, same as the main pipeline's `latest/`, and
is overridable the same way (`ARTIFACTS_DIR` env var or `--artifacts-dir=PATH`).
