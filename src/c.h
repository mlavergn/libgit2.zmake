/*
 * The libgit2 headers translated into the `c` module (`build.zig`).
 *
 * `git2.h` is the public API. The `sys/` headers are the extension points the
 * Zig side implements: the TLS stream (`tls_stream.zig`) and the errors it
 * reports through `git_error_set_str`.
 */

#include <git2.h>
#include <git2/sys/errors.h>
#include <git2/sys/stream.h>
