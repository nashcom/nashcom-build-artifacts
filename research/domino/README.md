# research/domino/

The investigation behind [docs/why-static-linking.md](../../docs/why-static-linking.md)
- test program for both use cases described there (Domino's bundled
libcurl, and bringing your own independent libcurl), on both Windows and
Linux. Not part of the main build pipeline.

```
curltest.cpp        source, shared between the Windows and Linux builds
mswin64.mak, mk.cmd  Windows build
makefile             Linux build (needs a Domino C-API SDK environment - see below)
nnotes.def
```

Linux build/test wiring (pulling the official Domino Container Image's
C-API option, with this pipeline's own `ARTIFACTS_DIR/latest` static libs
mounted in) is planned but not yet set up.
