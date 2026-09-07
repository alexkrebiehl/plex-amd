/*
 * Symbols that musl >= 1.2.3 provides and Plex's bundled musl 1.2.2 does not.
 *
 * Plex Media Server ships its own musl loader at
 * /usr/lib/plexmediaserver/lib/ld-musl-x86_64.so.1, and that loader refuses to
 * load a second libc (dynlink.c, "Catch and block attempts to reload the
 * implementation itself"), so the usual trick of bundling Alpine's
 * libc.musl-x86_64.so.1 alongside Mesa is silently ignored. The only way to
 * supply a missing libc symbol is to define it in a separate DSO and put that
 * DSO in the driver's DT_NEEDED chain. See README.md.
 *
 * Deliberately free of any libc dependency of its own - this is built with
 * -nostdlib so it introduces nothing that has to be resolved in turn.
 */

#include <stddef.h>

typedef int (*cmp_t)(const void *, const void *, void *);

static void swapbytes(char *a, char *b, size_t n)
{
	while (n--) {
		char t = *a;
		*a++ = *b;
		*b++ = t;
	}
}

static void siftdown(char *base, size_t n, size_t w, size_t i, cmp_t cmp, void *arg)
{
	for (;;) {
		size_t l = 2 * i + 1, m = i;
		if (l < n && cmp(base + l * w, base + m * w, arg) > 0)
			m = l;
		if (l + 1 < n && cmp(base + (l + 1) * w, base + m * w, arg) > 0)
			m = l + 1;
		if (m == i)
			return;
		swapbytes(base + i * w, base + m * w, w);
		i = m;
	}
}

/*
 * Heapsort: no allocation, O(n log n) worst case, and no libc calls. qsort is
 * not required to be stable, so this is a conforming implementation.
 */
void qsort_r(void *base_, size_t n, size_t w, cmp_t cmp, void *arg)
{
	char *base = base_;
	size_t i;

	if (n < 2 || w == 0)
		return;

	for (i = n / 2; i-- > 0; )
		siftdown(base, n, w, i, cmp, arg);

	for (i = n; i-- > 1; ) {
		swapbytes(base, base + i * w, w);
		siftdown(base, i, w, 0, cmp, arg);
	}
}
