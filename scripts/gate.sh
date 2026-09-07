#!/bin/sh
#
# Compatibility gates. Each one corresponds to a way this has actually broken,
# or a way it could break silently. None of them needs a GPU, so they all run on
# an ordinary CI runner.
set -eu

PLEX_LOADER=/plex/lib/ld-musl-x86_64.so.1
PLEX_LIBVA=/plex/lib/libva.so.2
PAYLOAD=/vaapi-amdgpu
OUR_LOADER="$PAYLOAD/lib/ld-musl-x86_64.so.1"
DRIVER="$PAYLOAD/lib/dri/radeonsi_drv_video.so"

fail() { echo "GATE FAILED: $*" >&2; exit 1; }

# musl's loader prints "musl libc (x86_64)\nVersion X.Y.Z" when run bare.
musl_version() { "$1" 2>&1 | sed -n 's/^Version //p' | head -1; }
as_int() { echo "$1" | awk -F. '{printf "%d", $1*10000 + $2*100 + $3}'; }

[ -e "$DRIVER" ] || fail "no driver at $DRIVER"
[ -x "$OUR_LOADER" ] || fail "no bundled loader at $OUR_LOADER"

echo "== gate 1: the driver relocates under the loader we ship =="
# musl relocates eagerly, so every symbol in the driver and its whole closure is
# resolved here. ldso_fail exits 127 before ldd mode's exit(0), so the exit code
# is trustworthy. This catches a dependency missing from the payload.
"$OUR_LOADER" --library-path "$PAYLOAD/lib" --list "$DRIVER"
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

echo "== gate 3: the loader we ship is newer than Plex's =="
# The whole design rests on this. Plex's musl 1.2.2 cannot dlopen this Mesa - it
# segfaults in the driver's constructors at an indirect call - so an init hook
# replaces Plex's bundled libc with this one at every start. If Plex ever catches
# up, the swap stops buying anything and this needs revisiting.
ours=$(musl_version "$OUR_LOADER")
theirs=$(musl_version "$PLEX_LOADER")
[ -n "$ours" ] || fail "could not read the bundled loader's version"
[ -n "$theirs" ] || fail "could not read Plex's loader version"
echo "  payload musl $ours vs Plex musl $theirs"
[ "$(as_int "$ours")" -ge "$(as_int "$theirs")" ] ||
	fail "the bundled loader ($ours) is older than Plex's ($theirs)"
if [ "$(as_int "$ours")" -eq "$(as_int "$theirs")" ]; then
	echo "  WARNING: identical musl versions - the swap is buying nothing"
fi

echo "== gate 4: every Plex binary still relocates under our loader =="
# The hook replaces Plex's bundled libc outright, so every Plex executable ends
# up running on the newer musl - not just the transcoder. musl is
# forward-compatible, but it does drop symbols occasionally (the LFS64 aliases
# went in 1.2.4), and a missing one would break Plex itself rather than merely
# lose hardware transcoding. Check them all.
bins=0
for b in /plex/*; do
	[ -f "$b" ] || continue
	[ "$(head -c 4 "$b" | tr -d "\0")" = "$(printf "\177ELF")" ] || continue
	bins=$((bins + 1))
	if ! out=$("$OUR_LOADER" --library-path /plex/lib --list "$b" 2>&1); then
		echo "$out" | grep -i "error\|not found" | head -3
		fail "$(basename "$b") does not relocate under musl $(musl_version "$OUR_LOADER")"
	fi
done
[ "$bins" -gt 0 ] || fail "found no Plex binaries to check"
echo "  $bins Plex binaries relocate cleanly"

echo "all gates passed"
