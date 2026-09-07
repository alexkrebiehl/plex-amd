#!/bin/sh
#
# Collect the Mesa VA driver, its complete DT_NEEDED closure, and the musl
# loader they were built against into a self-contained payload directory.
#
# The loader is the point of the exercise. Plex bundles musl 1.2.2, whose
# dlopen() cannot correctly load this Mesa - it segfaults in the driver's
# constructors. Shipping the newer loader and launching Plex Transcoder with it
# (see root/etc/cont-init.d/55-vaapi-transcoder) is what makes this work.
#
# Runs inside the Alpine builder stage. Argument is the payload root.
set -eu

DEST="${1:?usage: collect-libs.sh <dest>}"
mkdir -p "$DEST/lib/dri"

# Find a library by SONAME. Alpine ships plenty of SONAMEs as symlinks, so this
# must match symlinks too - a -type f search silently drops them and the failure
# surfaces much later as a confusing "No such file" from the loader.
find_lib() {
	find /usr/lib /lib -maxdepth 1 -name "$1" \( -type f -o -type l \) 2>/dev/null | head -1
}

needed_of() {
	readelf -d "$1" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'
}

# Transitive DT_NEEDED closure. libc is skipped here and handled separately
# below: musl resolves any "libc.*" DT_NEEDED to the running loader, never to a
# file on disk, so it must be shipped as the loader rather than as a dependency.
resolve() {
	for n in $(needed_of "$1"); do
		case "$n" in
		libc.* | ld-musl-*) continue ;;
		esac
		if [ -e "$DEST/lib/$n" ]; then
			continue
		fi
		src=$(find_lib "$n")
		if [ -z "$src" ]; then
			echo "MISSING: $n (needed by $1)" >&2
			exit 1
		fi
		cp -aL "$src" "$DEST/lib/$n"
		resolve "$DEST/lib/$n"
	done
}

echo "== collecting =="
cp -a /usr/lib/libgallium-*.so "$DEST/lib/"
for g in "$DEST"/lib/libgallium-*.so; do resolve "$g"; done

# Alpine ships this as a symlink to ../libgallium-<ver>.so; keep it that way so
# the 41 MB driver is not duplicated.
cp -a /usr/lib/dri/radeonsi_drv_video.so "$DEST/lib/dri/"

# The loader. In musl this file is also libc.
cp -aL /lib/ld-musl-x86_64.so.1 "$DEST/lib/ld-musl-x86_64.so.1"
chmod 0755 "$DEST/lib/ld-musl-x86_64.so.1"

# amdgpu_get_marketing_name() reads this; without it libdrm_amdgpu logs an error
# and the device reports an empty name.
mkdir -p "$DEST/share/libdrm"
cp -a /usr/share/libdrm/amdgpu.ids "$DEST/share/libdrm/"

echo "== rpath =="
# Every library finds its siblings relative to itself, so the payload resolves
# internally on its own. LD_LIBRARY_PATH is not an option: it is global to the
# container, and Ubuntu's glibc tooling would pick up these musl-linked
# libz/libstdc++ and break.
for f in "$DEST"/lib/*.so*; do
	[ -f "$f" ] && [ ! -L "$f" ] || continue
	case "$f" in *ld-musl-*) continue ;; esac
	patchelf --set-rpath '$ORIGIN' "$f"
done
# libva dlopens the driver as /vaapi-amdgpu/lib/dri/radeonsi_drv_video.so and
# musl expands $ORIGIN from that path without resolving the symlink, so $ORIGIN
# is .../dri at that moment. $ORIGIN/.. is what actually reaches the payload.
for g in "$DEST"/lib/libgallium-*.so; do
	patchelf --set-rpath '$ORIGIN:$ORIGIN/..' "$g"
done

echo "== payload =="
"$DEST/lib/ld-musl-x86_64.so.1" 2>&1 | sed -n '1,2p' | sed 's/^/bundled loader: /'
du -sh "$DEST"
ls -1 "$DEST/lib" | wc -l | sed 's/^/libraries: /'
