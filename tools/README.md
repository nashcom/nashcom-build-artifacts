# tools/

Standalone pipeline: builds static, stripped `openssl` + `curl` CLI binaries
from source on Alpine (musl libc) — not part of the main UBI9 pipeline, and
not for linking into Domino addins. See the main
[README](../README.md#standalone-static-cli-binaries-tools) for details.

```bash
./build.sh
```

Output: `bin/openssl`, `bin/curl`.
