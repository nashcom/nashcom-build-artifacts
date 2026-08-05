# Using libcurl from Domino C-API applications

This investigation is what motivated the `nashcom-build-artifacts` build pipeline.

## Use case

I need libcurl functionality in Domino C-API applications. `nnotes.dll` / `libnotes.so` includes its own private copy of libcurl.
But this is not public C-API functionality and there is currently no documented, supported API for making outbound HTTP(S) calls directly from a C-API application.
I tested two distinct approaches.

## Use case 1: Use Domino's bundled libcurl

**Not recommended.** This interface is undocumented, has no support commitment, and it only supports HTTP(S).
It is documented here because I investigated and tested it, not because it is a recommended integration path.

Domino statically links libcurl into `nnotes.dll` / `libnotes.so` on both platforms, but accessing those symbols works differently on Windows and Linux.

### Windows

The symbols are privately versioned (`curl_easy_init@@noteslib_v1.00`). Calling them directly works with a self-built import library for the actual exported symbols.
A renaming `.def` import library does not work: the application links successfully, but loading fails at runtime because the renamed procedure entry point does not exist.

### Linux

There is no separate import library. The symbols are resolved directly from `libnotes.so`.
This is also the important difference for use case 2: a function dynamically linked `curl_easy_*` reference can be satisfied by the symbols already provided by `libnotes.so`.
That is useful when Domino's bundled curl is intentionally being used, but prevents a normally linked second libcurl from being reliably independent.

## Use case 2: Bring your own independent libcurl

### Windows

A separate dynamically linked libcurl, including its own SSL stack, can coexist cleanly with Domino's bundled curl.
I verified this by interleaving my own libcurl calls with `NotesHTTPRequest`, including calls after my own `curl_global_cleanup()`.
No conflicts were observed. The only missing component for my build was an MSVC import library for the selected libcurl DLL, which I generated using `.def` / `lib.exe`.

### Linux

Dynamic linking on Linux does **not** provide the same isolation.
In my tests, my own libcurl calls and Domino's bundled libcurl resolved to the same function addresses.

Both consequently reported Domino's libcurl version.
This is an ordinary ELF symbol-resolution/link-order issue, not a Domino defect: with `-lnotes` ahead of another curl library,
the unversioned `curl_easy_*` references can already be satisfied by `libnotes.so`.

The failure is particularly difficult to detect because there is no linker or runtime error.
The application runs successfully, but uses a different libcurl implementation than intended.

For normal linker-based integration, the reliable solution is to statically link the application's own libcurl and its SSL implementation into the C-API application.
I confirmed the resulting isolation by comparing function addresses: once my libcurl and OpenSSL were statically linked, Domino and the application used different implementations.

On Redhat based platforms, the required static libraries are not available through the standard packages I tested, so libcurl and OpenSSL have to be built from source.
The libraries also have to be built as a matched set against the intended deployment ABI.
In particular, libcurl must be built against the same OpenSSL artifacts that are subsequently linked into the application.
Building against incompatible system/runtime ABIs can result in ELF symbol-version errors at runtime.

## Path forward

1. **Windows:** Use an official libcurl build with its own SSL stack and the corresponding MSVC import library.
2. **Linux:** Build and statically link a matched set of libcurl + OpenSSL (+ zlib) for the target RHEL/UBI ABI.
3. **Linux linking:** Explicitly document and verify link order and the resulting ELF dependencies so that references cannot silently resolve to Domino's bundled libcurl.

## Why `nashcom-build-artifacts` exists

`nashcom-build-artifacts` is the direct answer to the Linux requirement above.
It provides a reproducible build pipeline for matched static **libcurl + OpenSSL + zlib** artifacts, built together against the same **UBI 9 / RHEL 9 ABI** used by the target Domino environment.

The goal is not merely to provide static libraries.
It is to provide a **known, reproducible, mutually compatible set of build artifacts** that can be consumed by Domino C-API projects without accidentally depending on Domino's private libcurl implementation or on incompatible libraries from the build host.
