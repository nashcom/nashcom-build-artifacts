# Using libcurl from Domino C-API applications

Copied from [D:\claude\curltest\LIBCURL_FINDINGS.md](../../curltest/LIBCURL_FINDINGS.md)
— this is the investigation that motivated this whole build pipeline.

## Use case

We need libcurl functionality in C-API applications. `nnotes.dll` /
`libnotes.so` bundles its own private copy of curl internally (OIDC SSO,
`DominoCurl`, etc.), but it isn't public API, and there's no documented,
supported way to make outbound HTTP(S) calls from a C-API application
today. We tested two distinct approaches.

## Use case 1: use Domino's own (bundled) libcurl

- Domino statically links libcurl into nnotes.dll/libnotes.so. Confirmed
  via export inspection on both platforms - on Linux the symbols are
  privately versioned (`curl_easy_init@@noteslib_v1.00`). Internal
  callers include `InitOIDCCurl`/`DeinitOIDCCurl` and a `DominoCurl`
  class.
- Calling it directly: explicit dynamic loading by name
  (`GetProcAddress` / `dlsym`) works. A renaming `.def` import library
  does not - links fine, fails at runtime ("procedure entry point could
  not be located").
- Open question: does sharing `curl_global_init`/`curl_global_cleanup`
  with Domino's own internal curl usage carry any real risk
  (ref-counting, concurrent use)? No interference observed in either
  direction in our testing, but that's empirical, not a guarantee.

## Use case 2: bring your own, independent libcurl

### Windows

A separate, dynamically-linked libcurl (own SSL stack bundled in the
DLL) coexists cleanly with Domino's own curl usage - no conflicts, even
with `NotesHTTPRequest` interleaved with our own calls, including after
our own `curl_global_cleanup()`. Only missing piece: an official MSVC
import library for the bundled DLL (we hand-built one via
`.def`/`lib.exe`).

### Linux

Dynamic linking does **not** give real independence: our own curl and
Domino's resolved to the *same* function address despite Domino's
version scripting - an ordinary link-order issue (`-lnotes` ahead of our
own curl on the command line satisfies the unversioned reference first),
not a Domino bug. Fails silently, same version string both sides, no
link/runtime error.

**Static linking of both libcurl and OpenSSL is required** to get real
independence (confirmed via differing addresses once static). Neither is
packaged on RHEL 9 or RHEL 10 - both have to be built from source, and
the OpenSSL libcurl is linked against has to match the *deployment*
machine's ABI, not just the build machine's, or you get a runtime
symbol-version error.

## Path forward

1. Ship libcurl headers with the C-API, matching the bundled version -
   needed for use case 1.
2. Ship an official Windows import library for the bundled exports -
   needed for use case 1.
3. Ship an official Windows libcurl (with its own SSL stack) plus import
   library for use case 2.
4. Ship matched static libs for **both** libcurl and OpenSSL for Linux,
   for use case 2 - they have to be built against each other, and a
   mismatch is exactly the runtime error we hit ourselves.
5. Document both use cases explicitly: the Linux link-order requirement
   for use case 2, and an authoritative answer on the init/cleanup
   sharing question for use case 1.

---

**This project (`nashcom-build-artifacts`) is the direct answer to point 4** —
a reproducible pipeline building matched static curl + openssl (+ zlib)
against the same UBI9/RHEL9 ABI Domino itself deploys on.

## CA certificates

Static linking solves the ABI-independence problem, but it doesn't solve CA
trust — that's a separate gap this project doesn't (and can't) close for you.

Neither curl's nor OpenSSL's **source** ships a CA bundle — that's true
upstream, and it's just as true of the static libs this pipeline builds. Our
OpenSSL build configures `--openssldir=/depends/openssl/ssl`, which bakes in
a default cert path that only exists inside the build container; it's gone
the moment the libs are copied out to `latest/` and linked into your own
addin. Concretely: a real TLS connection made through the shipped `.a`
libraries — or through the `openssl`/`curl` CLI tools built alongside them —
fails with `Problem with the SSL CA cert (path? access rights?)` unless
*your own code* handles CA verification explicitly.

There's no single fix this repo could bake in instead, because there's no
universal trust-store location to bake in: RHEL/UBI9, Debian/Ubuntu, and
Alpine each keep their system CA bundle in a different place, and Windows
(the original context for this investigation — see the top of this doc) has
no system trust store at all. Whatever your C-API addin links against these
libs needs to do this itself — same pattern `project/testing/test_openssl.cpp`
and `test_curl.cpp`'s `FindCaBundle()` demonstrate: try a local override file
first, then a short list of known system paths, and fail predictably (not
silently) if none match.

A more rigorous, fully closed-loop verification of this — a self-signed CA
plus `openssl s_server`, with no dependency on any OS's trust store or a live
internet host — is planned as a separate follow-up test suite, not yet
built.
