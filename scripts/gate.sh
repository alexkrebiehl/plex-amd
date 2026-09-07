#!/bin/sh
#
# Compatibility gates. Each one corresponds to a way this has actually broken,
# or a way it could break silently. None of them needs a GPU, so they all run on
# an ordinary CI runner.
set -eu

LOADER=/plex/ld-musl-x86_64.so.1
PLEX_LIBVA=/plex/libva.so.2
PAYLOAD=/vaapi-amdgpu
DRIVER="$PAYLOAD/lib/dri/radeonsi_drv_video.so"

fail() { echo "GATE FAILED: $*" >&2; exit 1; }

[ -e "$DRIVER" ] || fail "no driver at $DRIVER"

echo "== gate 1: relocation against Plex's own musl loader =="
# musl relocates eagerly, so every symbol in the driver and its entire closure is
# resolved here exactly as it would be at dlopen() time inside Plex Transcoder.
# A missing symbol sets ldso_fail, which exits 127 before ldd mode's exit(0), so
# the exit code is trustworthy.
"$LOADER" --library-path "$PAYLOAD/lib" --list "$DRIVER"
echo "  relocation clean"

echo "== gate 2: libva ABI =="
# libva's va_openDriver() looks for __vaDriverInit_<major>_<minor>, counting DOWN
# from its own minor version. A Mesa built against a NEWER libva than Plex's
# exports only a higher minor, so Plex's libva never finds an entry point - and
# the symptom is a silent fall back to CPU transcoding with no error anywhere.
drv_minor=$(readelf -sW "$DRIVER" |
	sed -n 's/.*__vaDriverInit_1_\([0-9][0-9]*\).*/\1/p' | sort -n | head -1)
plex_minor=$(strings "$PLEX_LIBVA" |
	sed -n 's#.*libva/2\.\([0-9][0-9]*\)\.[0-9].*#\1#p' | head -1)
[ -n "$drv_minor" ] || fail "driver exports no __vaDriverInit_1_N"
[ -n "$plex_minor" ] || fail "could not determine Plex's libva version"
echo "  driver exports __vaDriverInit_1_$drv_minor; Plex ships VA-API 1.$plex_minor"
[ "$drv_minor" -le "$plex_minor" ] ||
	fail "driver was built against a newer libva than Plex ships; Plex would never load it"

echo "== gate 3: no second libc in the payload =="
# musl blocks loading a second libc (dynlink.c, "Catch and block attempts to
# reload the implementation itself"), so one bundled here would be silently
# ignored and give a false sense that a version gap had been papered over.
if ls "$PAYLOAD"/lib/libc.musl-* "$PAYLOAD"/lib/ld-musl-* >/dev/null 2>&1; then
	fail "payload bundles a libc; musl will ignore it (use the shim instead)"
fi
echo "  clean"

echo "all gates passed"
