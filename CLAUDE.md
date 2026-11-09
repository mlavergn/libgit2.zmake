# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Builds libgit2 with only the Zig toolchain (no CMake), and exposes it through an idiomatic Zig API. The CLI is libgit2's own `git2`. Same approach as the sibling `../llama.cpp.zmake`: the upstream C sources (libgit2, libssh2, mbedTLS) are `build.zig.zon` packages pinned by hash and are **never modified**. If upstream seems to need a change, the build description is wrong.

Success means libgit2's own clar suites pass against the Zig-built library (`zig build clar`). They run only on macOS; Linux and Windows are checked by cross-compiling.

Zig **0.17.0**. On macOS the build needs the Xcode SDK (resolved via `zigbuildx.Xcode`). Targets: Darwin, Linux, Windows; `build/libgit2.zig` fails configuration with `UnsupportedTargetOs` for anything else rather than guess its settings.

## Build / Test

```sh
make validate               # pre-commit gate: clean, format, lint, build, test
make test                   # Zig unit tests (src/ and the zig/ host tools)
make clar                   # libgit2's clar suites (offline + util); deliberately not in validate
zig build test -Dtest-filter="status"   # one test by name
make cli ARGS="--version"   # build git2 optimized and run it (`make run`: debug)
make linux | make windows   # cross-compile
zig build -Dverbose-build    # trace the build/ description as it runs
```

`format`, `lint`, and `validate` come from `-include ../styleguide/Makefile.in`. They need the sibling `../styleguide` checkout, and `lint` needs `zlint` on `PATH`. `ZIG_DIRS` in the Makefile adds `build/` and `zig/` to what they cover.

## Module layout

- `build/`: the C build description, one file per upstream package, plus `clar.zig`. Each package is a **C-only module** imported by the library module. Imported modules' objects land in the static archive; `linkLibrary`'d archives do not. Never link `lib` into an artifact that already imports the module, or every symbol is defined twice.
- `zig/`: host tools the build runs. `clar_generate.zig` is a byte-identical port of clar's `generate.py`. `clar_fixtures.zig` restores fixture file modes.
- `src/module.zig`: the library barrel. It also re-exports the translated C API as `c` and the build options as `config`. `src/c.h` is what gets translated.
- `src/tls_stream.zig`: HTTPS for libgit2, over `std.crypto.tls`. It is registered at runtime because libgit2 is compiled with no HTTPS backend. A stream is `connected` only after its handshake succeeds. libgit2 closes and frees streams whose connect failed, so `close` must never touch the TLS client otherwise. A registration or a live stream holds a reference on the shared trust store.
- `src/timed_socket.zig`: the TLS stream's socket reader and writer, timed through `std.Io.operateTimeout`. They honor libgit2's `GIT_OPT_SET_SERVER_TIMEOUT` and `GIT_OPT_SET_SERVER_CONNECT_TIMEOUT`. Don't use `SO_RCVTIMEO`: std treats the `EAGAIN` it causes as a bug.
- `src/root.zig`: exists only so autodoc can root the docs build. Don't add code to it.
- `cli/main.zig`: the CLI's entry point. It initializes libgit2, registers the TLS stream, then calls upstream's `main`. `build/git2_cli.zig` compiles the package's `src/cli/main.c` with `-Dmain=ziglibgit2_git2_main`. `src/cli/...` paths in `build/` are inside the libgit2 package, not this repo.

## Backends

| | Choice | CMake's default |
|---|---|---|
| HTTPS | Zig `std.crypto.tls`, registered at runtime as libgit2's TLS stream | SecureTransport / OpenSSL / WinHTTP |
| SSH | libssh2 1.11.1 + mbedTLS 3.6.7 (default `mbedtls_config.h`, `mbedcrypto` only) | system libssh2, if found |
| zlib, regex, HTTP parser | bundled in libgit2, on every platform | system zlib; `regcomp_l` on macOS |
| SHA1 / SHA256 | collision detection / builtin | the same, with no HTTPS backend |
| NTLM, GSSAPI | off | NTLM on, through the HTTPS backend's crypto |

Consequences of these choices, all intended:
- `git_libgit2_features()` doesn't report HTTPS, though it works: `GIT_HTTPS` stays undefined.
- HTTPS exists only after `mod.Libgit2.init` registers the TLS stream. C code that links `libziglibgit2.a` and calls `git_libgit2_init` itself gets none (`cli/main.zig` registers the stream for `git2`).
- `certificate_check` callbacks receive `GIT_CERT_NONE`. `std` doesn't expose the peer's X.509, and an untrusted certificate fails the handshake before the callback runs. Trust comes from the OS root store only.
- Zig's TLS offers fewer cipher suites than OpenSSL or SecureTransport. Servers limited to TLS 1.2 with CBC ciphers won't connect.
- SSH runs one thread at a time. libssh2's mbedTLS backend shares one random-number generator, and the default mbedTLS config has no `MBEDTLS_THREADING_C`, as with CMake.

## Architecture conventions

@../styleguide/ZIGSTYLE.md

ZIGSTYLE is authoritative. When code conflicts with it, change the code. Key points:
- Use one primary struct per file, named for its role in snake_case. Every multi-file directory has a `module.zig` barrel (`src/`, `build/`, `zig/`), and siblings import through it.
- Never nest types. Put supporting types above the primary struct, and export public ones through the barrel (`GitErrorSet`, `RevwalkSort`, `StatusEntry`, `PassphraseFn`). The only alias is `const Self = @This();`.
- Every file, `build/` included, declares a scoped logger: `.ziglibgit2_<file>`, or `.ziglibgit2_build_<file>` in `build/`. Its main functions trace entry with `@src()`. Barrels are exempt, and so are per-read and per-write paths, where a trace would cost on every packet.
- `init` returns `!Self`, even when nothing can fail.
- Give every public declaration a `///` comment, struct fields and barrel exports included.
- Write doc comments as ZIGSTYLE E.1.b says: one ``- `name`:`` bullet per parameter, then `- Returns:`, on private functions too wherever they have a `///` comment. Explain *why*.
- Never alias namespaces (`const c = mod.c;` is a violation); use `mod.c.*`.
- In `build/`, cite the upstream CMake line every flag, define, or source list comes from, and check that the line number is right.
- `build/` entry traces go behind `if (cfg.verbose)`. The build script re-runs whenever the configured graph goes stale, in dependent packages too, so ungated traces print each time.
- Never use deprecated Zig APIs. `@cImport` is gone; the C API comes from `b.addTranslateC`.

## Project-state heads-ups

- translate-c makes `git_stream` opaque because of its bitfields. `tls_stream.zig` declares the layout by hand, and `src/abi_probe.c` checks it from the unit tests. That probe is compiled into a separate test module so it stays out of the archive.
- The upstream C modules compile with `.sanitize_c = .off`. Zig enables UBSan in Debug, CMake never does, and the sources are not clean under it.
- `zig fetch` keeps the executable bit only on `#!` files. `build/clar.zig` lists the 16 fixtures that need it restored. Re-derive that list when the libgit2 pin moves.
- clar's `checkout::icase::overwrites_links_for_folders_when_forced` fails on macOS 27, so `make clar` stays strict and out of `make validate`. Don't exclude the suite. The cause is upstream: `futils.c` runs `lstat` on `a/`, the trailing slash follows the `A -> ..` symlink, and the final `rmdir("a/")` gets `EINVAL`. Apple's compiler gives the same result. Upstream's CI tests on `macos-14` (`.github/workflows/main.yml:67`).
- The `.version` in `build.zig.zon` tracks the libgit2 release being built, and a unit test enforces it. Bump it whenever the libgit2 pin moves. `make tag` tags and pushes that version.
- Moving a pin: `zig fetch --save=<libgit2|libssh2|mbedtls> <tarball url>`. Use GitHub's `archive/refs/tags/*.tar.gz` for mbedTLS, because its release asset is `.tar.bz2`, which `zig fetch` can't read. Then re-check every CMake citation in `build/`, re-derive the executable fixtures, and run `make clar`. With no network tests, clar is the only check.
- libssh2's mbedTLS backend has no ed25519 (`LIBSSH2_ED25519 0`). ed25519 works only through ssh-agent, which does the signing (verified: a GitHub clone via `mod.Credentials`). ed25519 key files fail; RSA and ECDSA key files work. The `git2` CLI sets no credential callback, so it has no SSH auth at all.

## Not yet implemented

- Bindings cover `Repository`, `Oid`, `Reference`, `Commit`, `Revwalk`, `Status` and `Credentials` only. Index, tree, diff, remote and config work goes through `mod.c`.
- HTTPS over HTTP CONNECT proxies (`TlsStream` has no `wrap`). No HTTPS credentials in `Credentials`.
- No automated network tests. TLS and SSH are checked by hand with `git2 clone`.
