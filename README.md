# plex-amd

Plex Media Server with a working AMD VAAPI driver, for hardware transcoding on an AMD GPU or iGPU.

Published to `ghcr.io/alexkrebiehl/plex-amd:latest`. Consumed by
`flux-kustomizations/base/plex/release.yaml` on the home Kubernetes cluster, where the render node
is supplied by [`generic-device-plugin`](https://github.com/squat/generic-device-plugin) as the
extended resource `devic.es/dri`.

## Why this exists

**The official Plex image contains no VA driver.** Not a broken one, not an outdated one — none.
Verified against the current release: there is no `*_drv_video.so` anywhere in
`plexmediaserver_*_amd64.deb`, and the bundled `libva.so.2` still points at a leftover CI build path
from Plex's own build machine:

```
/home/runner/_work/plex-conan/plex-conan/.conan/data/libva/2.22.0-0/plex/main/build/.../install/lib/dri
```

`linuxserver/plex` ships none either. So hardware transcoding on AMD needs a driver supplied from
somewhere else, and this repo supplies it.

Getting the *device* into the container is a separate problem, solved separately by the device
plugin. This repo solves only the *driver* problem.

## How it works

An Alpine builder collects Mesa's `radeonsi_drv_video.so` and its complete `DT_NEEDED` closure into
`/vaapi-amdgpu`, and the final image sets one environment variable:

```
LIBVA_DRIVERS_PATH=/vaapi-amdgpu/lib/dri
```

Plex's own `libva` picks the driver up from there. The payload lives outside
`/usr/lib/plexmediaserver` on purpose — see "How Plex stays up to date".

## Why a shim

This is the expensive fact. **Plex bundles musl 1.2.2. Alpine's Mesa needs musl 1.2.3 or newer.**

Plex ships its own loader at `/usr/lib/plexmediaserver/lib/ld-musl-x86_64.so.1`; its version banner
says `1.2.2` and its `.dynsym` has no `qsort_r`, which musl added in 1.2.3. Mesa's `libgallium`
needs `qsort_r`, so loading Alpine's Mesa into Plex Transcoder fails with:

```
Error relocating /vaapi-amdgpu/lib/dri/radeonsi_drv_video.so: qsort_r: symbol not found
```

Every Alpine from 3.17 to 3.22 (Mesa 22.2.5 through 25.1.9) fails identically, and Mesa below 22.2
does not support this generation of hardware, so no version threads the needle.

**Bundling Alpine's `libc.musl-x86_64.so.1` alongside does not help**, even though it looks like it
should, and this is what other AMD/Plex mods do. musl's loader hard-blocks reloading its own
implementation — `ldso/dynlink.c`:

```c
/* Catch and block attempts to reload the implementation itself */
if (name[0]=='l' && name[1]=='i' && name[2]=='b') {
        static const char reserved[] = "c.pthread.rt.m.dl.util.xnet.";
        ...
        is_self = 1;
```

Any `DT_NEEDED` beginning `libc.` resolves to the *running* loader — Plex's 1.2.2. The second copy
is silently ignored.

What does work is defining the missing symbol in a *separate* DSO and putting that DSO in the
driver's dependency chain. That is `shim/plexcompat.c` → `libplexcompat.so.1`, attached with
`patchelf --add-needed` to every library that actually references one of its symbols.
`qsort_r` needs nothing from libc internals, so the shim is a self-contained heapsort built with
`-nostdlib` and introduces no dependencies of its own.

The full dependency closure was resolved and every undefined symbol diffed against Plex's musl
exports: **`qsort_r` is the only real gap.** Everything else is either provided by a bundled library
or is a weak symbol (`_ITM_*`, `_ZGTt*`, `_ZTH*`, `ZSTD_trace_*`) that is expected to be unresolved.

## Why no `LD_LIBRARY_PATH`

`LD_LIBRARY_PATH` is global to the container. The base image is Ubuntu, and Plex's own startup
scripts run `bash`, `curl`, `xmlstarlet` and `dpkg` — all glibc binaries. Pointing
`LD_LIBRARY_PATH` at a directory full of musl-linked `libz.so.1` and `libstdc++.so.6` breaks them.

Instead every library in the payload gets `RPATH=$ORIGIN` (and `$ORIGIN:$ORIGIN/..` for
`libgallium`, since `libva` dlopens the driver through the `dri/` symlink and musl expands `$ORIGIN`
from that path without resolving it). Resolution is then entirely internal to the payload, and
nothing outside it is affected.

## The libva version trap

`libva`'s `va_openDriver()` looks for `__vaDriverInit_<major>_<minor>`, counting **down** from its
own minor version. Mesa exports exactly one such symbol, fixed by the libva it was built against.

So a Mesa built against a **newer** libva than Plex ships exports only a higher minor, Plex's libva
never finds an entry point, and the symptom is a silent fall back to CPU transcoding with no error
message anywhere. Today the driver exports `__vaDriverInit_1_22` and Plex ships libva 2.22.0
(VA-API 1.22) — an exact match, but not one to take for granted. Gate 2 asserts it on every build.

## How Plex stays up to date

Nothing in this repo controls it, by design.

The image is built `FROM plexinc/pms-docker:public`. That tag contains **no** Plex binary; instead
`/etc/cont-init.d/50-plex-update` runs at every container start, reads `version=public` from
`/version.txt`, asks plex.tv for the newest release on the public channel (which needs no Plex
token), and `dpkg -i`s it. Since this image adds only `/vaapi-amdgpu` and never touches
`/usr/lib/plexmediaserver` or `/version.txt`, a Plex upgrade cannot disturb the driver, and the
driver cannot pin Plex to an old version.

On the cluster a CronJob restarts the Plex pod nightly, so Plex updates itself daily. This image
inherits that unchanged.

CI therefore only rebuilds for **Mesa and base-image** changes: on push, and weekly. The weekly
build is also a canary — it downloads the *current* Plex release and re-runs the gates, so if a
future Plex bumps musl or libva, CI goes red rather than transcoding silently dropping to CPU.

## Gates

`scripts/gate.sh` runs in its own build stage. None of it needs a GPU.

1. **Relocation.** Plex's own musl loader resolves every symbol in the driver and its whole closure:
   `ld-musl-x86_64.so.1 --library-path ... --list radeonsi_drv_video.so`. musl relocates eagerly, so
   this fails exactly where `dlopen()` would, and `ldso_fail` exits 127 before ldd mode's `exit(0)`,
   which makes the exit code trustworthy.
2. **libva ABI.** The driver's exported `__vaDriverInit_1_N` must not exceed Plex's libva minor.
3. **No second libc** in the payload, which would be silently ignored and hide a real version gap.

## Building and testing locally

```sh
docker buildx build --target gate .            # the three gates
docker buildx build --load -t plex-amd:test .  # the image
```

## Verifying against real hardware

The driver only proves itself on a machine with the GPU. This exercises device access, driver load,
symbol resolution and the libva handshake in one shot:

```sh
docker run --rm --device /dev/dri/renderD128 --entrypoint /bin/bash plex-amd:test -c '
  /usr/lib/plexmediaserver/Plex\ Transcoder -hide_banner \
    -init_hw_device vaapi=hw:/dev/dri/renderD128 -filter_hw_device hw \
    -f lavfi -i testsrc=size=1280x720:rate=30 -t 2 \
    -vf format=nv12,hwupload -c:v h264_vaapi -f null -'
```

Expect frames encoded, and no `Failed to initialise VAAPI` or `va_openDriver() returns -1`. Add
`LIBVA_MESSAGING_LEVEL=2` to see libva's driver search.

Note that `:public` downloads Plex at container start, so `Plex Transcoder` only exists after the
container has run its init scripts once.

## Turning it on

Hardware transcoding is a *server* setting, not a container setting:
**Plex → Settings → Transcoder → "Use hardware acceleration when available"**. Requires Plex Pass.
This image makes it possible; nothing here can enable it.

## Layout

```
Dockerfile                    four stages: plex-ref, mesa, gate, image
shim/plexcompat.c             musl >= 1.2.3 symbols Plex's 1.2.2 lacks
scripts/collect-libs.sh       DT_NEEDED closure, RPATH, shim attachment
scripts/gate.sh               the three compatibility gates
.github/workflows/build.yml   push + weekly build to ghcr.io
```
