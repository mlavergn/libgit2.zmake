# ziglibgit2

> libgit2 built with nothing but the Zig toolchain, with a Zig API and libgit2's own `git2` CLI.

## Overview

The libgit2 C sources are built exactly as upstream releases them: `build.zig` takes the place of CMake, and nothing upstream is patched. HTTPS uses Zig's standard library, and SSH uses libssh2 with mbedTLS, also built with Zig, so the build needs no system libraries. Use it as a Zig package (the `ziglibgit2` module, or one static archive), or as the `git2` command line. libgit2's own test suites check the result.

## Requirements

- Zig 0.17.0
- Target platforms: macOS (Apple Silicon), Linux (ARM / x86_64), Windows (x86_64)
- macOS: the Xcode SDK. Nothing else: no CMake, Python, or OpenSSL.

## Setup

```sh
git clone git@github.com:mlavergn/ziglibgit2.git
cd ziglibgit2
make            # build, format, test
make clar       # libgit2's own test suites
```

`make validate`, `make format` and `make lint` need the sibling `../styleguide` checkout, and `zlint` for `lint`.

## Configuration

Nothing at build time, and no environment variables. At runtime:

- HTTPS trusts the operating system's root certificates.
- SSH (Zig API) tries ssh-agent, then `~/.ssh/id_ed25519`, `id_ecdsa` and `id_rsa`, and checks hosts against `~/.ssh/known_hosts`. ed25519 keys work only through ssh-agent (`ssh-add ~/.ssh/id_ed25519`).
- The `git2` CLI supports HTTPS but not SSH authentication.

## Usage

```sh
make cli ARGS="--version"
zig-out/bin/git2 clone https://github.com/libgit2/TestGitRepository demo
```

From Zig:

```zig
const mod = @import("ziglibgit2");

var lib = try mod.Libgit2.init(allocator, io);
defer lib.deinit();

var repo = try mod.Repository.open(allocator, ".");
defer repo.deinit();
```

## Architecture

```
build.zig   entry point: steps, options, the Zig module, CLI, tests
build/      the C build description that replaces CMake
src/        the Zig API; HTTPS for libgit2 (tls_stream.zig)
cli/        the git2 CLI's entry point
zig/        host tools the build runs (clar test-suite generation)
```
