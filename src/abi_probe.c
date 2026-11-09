/*
 * Reads a git_stream through the C compiler's view of its layout.
 *
 * translate-c cannot represent the `encrypted`/`proxy_support` bitfields, so
 * it makes git_stream opaque and `tls_stream.zig` declares the layout itself.
 * This probe is compiled into the unit tests only, which fill that Zig layout
 * and check that C reads back the same fields.
 */

#include <stddef.h>
#include <git2.h>
#include <git2/sys/stream.h>

size_t ziglibgit2_git_stream_size(void)
{
	return sizeof(git_stream);
}

int ziglibgit2_git_stream_probe(const git_stream *s, int *encrypted, int *proxy_support, int *timeout, int *connect_timeout, void **read, void **free_fn)
{
	*encrypted = s->encrypted;
	*proxy_support = s->proxy_support;
	*timeout = s->timeout;
	*connect_timeout = s->connect_timeout;
	*read = (void *)s->read;
	*free_fn = (void *)s->free;
	return s->version;
}
