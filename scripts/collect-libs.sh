#!/bin/sh
#
# Collect the Mesa VA driver and its complete DT_NEEDED closure into a
# self-contained payload directory, then make that payload resolve internally
# so it needs no LD_LIBRARY_PATH at runtime.
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

# Transitive DT_NEEDED closure. libc is skipped unconditionally: musl always
# resolves a "libc.*" DT_NEEDED to the running loader, which at runtime is
# Plex's own musl. Copying Alpine's would be dead weight at best.
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

# amdgpu_get_marketing_name() reads this; without it libdrm_amdgpu logs an error
# and the device reports an empty name.
mkdir -p "$DEST/share/libdrm"
cp -a /usr/share/libdrm/amdgpu.ids "$DEST/share/libdrm/"

echo "== rpath =="
# Every library finds its siblings relative to itself. This is what replaces
# LD_LIBRARY_PATH, which cannot be used here: it is global to the container and
# Ubuntu's glibc tooling would pick up these musl-linked libz/libstdc++ and break.
for f in "$DEST"/lib/*.so*; do
	[ -f "$f" ] && [ ! -L "$f" ] || continue
	patchelf --set-rpath '$ORIGIN' "$f"
done
# libva dlopens the driver as /vaapi-amdgpu/lib/dri/radeonsi_drv_video.so and
# musl expands $ORIGIN from that path without resolving the symlink, so $ORIGIN
# is .../dri at that moment. $ORIGIN/.. is what actually reaches the payload.
for g in "$DEST"/lib/libgallium-*.so; do
	patchelf --set-rpath '$ORIGIN:$ORIGIN/..' "$g"
done

echo "== compat shim =="
shim_syms=$(readelf -sW "$DEST/lib/libplexcompat.so.1" |
	awk '$5=="GLOBAL" && $7!="UND" && $8!="" {sub(/@.*/,"",$8); print $8}' | sort -u)
echo "shim provides: $(echo "$shim_syms" | tr '\n' ' ')"

attached=0
for f in "$DEST"/lib/*.so*; do
	[ -f "$f" ] && [ ! -L "$f" ] || continue
	case "$f" in *libplexcompat*) continue ;; esac
	und=$(readelf -sW "$f" | awk '$7=="UND" && $8!="" {sub(/@.*/,"",$8); print $8}' | sort -u)
	for s in $shim_syms; do
		if echo "$und" | grep -qx "$s"; then
			echo "  + $(basename "$f") needs $s"
			patchelf --add-needed libplexcompat.so.1 "$f"
			attached=$((attached + 1))
			break
		fi
	done
done
if [ "$attached" -eq 0 ]; then
	echo "  note: nothing needed the shim (Mesa or musl may have moved)"
fi

echo "== payload =="
du -sh "$DEST"
ls -1 "$DEST/lib" | wc -l | sed 's/^/libraries: /'
