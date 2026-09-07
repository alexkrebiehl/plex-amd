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

## Why the loader is the crux

This is the expensive fact, and it is not the one it first appears to be.

**Plex bundles musl 1.2.2.** Its loader lives at `/usr/lib/plexmediaserver/lib/ld-musl-x86_64.so.1`
and its version banner says `1.2.2`. Alpine's Mesa is built against musl 1.2.5.

The first symptom is a missing symbol — `qsort_r`, which musl added in 1.2.3:

```
Error relocating .../radeonsi_drv_video.so: qsort_r: symbol not found
```

That one is fixable, and bundling Alpine's `libc.musl-x86_64.so.1` alongside is *not* how (which is
what other AMD/Plex mods try). musl's loader hard-blocks reloading its own implementation —
`ldso/dynlink.c`:

```c
/* Catch and block attempts to reload the implementation itself */
if (name[0]=='l' && name[1]=='i' && name[2]=='b') {
        static const char reserved[] = "c.pthread.rt.m.dl.util.xnet.";
        ...
        is_self = 1;
```

Any `DT_NEEDED` beginning `libc.` resolves to the *running* loader. The second copy is ignored.

**But fixing the symbol is not enough.** With `qsort_r` supplied by a shim, relocation succeeded and
the driver still died — libva found and opened it, then the process took a `SIGSEGV`:

```
libva: Trying to open /vaapi-amdgpu/lib/dri/radeonsi_drv_video.so
Segmentation fault
```
```
Plex Transcoder[140460]: segfault at 2100 ip 0000000000002100 error 14
```

`ip` equal to the fault address, at a tiny value, is an indirect call through a bogus function
pointer — inside the driver's constructors, which run during `dlopen` and which the relocation-only
check never exercises.

The A/B that settles it: **same transcoder binary, same driver, same GPU, only the loader changed.**

| Loader | Result |
|---|---|
| Plex's musl 1.2.2 | `SIGSEGV` during `dlopen` of the driver |
| Alpine's musl 1.2.5 | 30 frames encoded, `h264_vaapi`, `speed=2.16x`, exit 0 |

So the fix is not a shim — it is to run the transcoder under the newer loader. The payload ships
`ld-musl-x86_64.so.1` from the same Alpine as Mesa, and `/etc/cont-init.d/55-vaapi-transcoder`
replaces `Plex Transcoder` with a wrapper that exec's it:

```sh
exec /vaapi-amdgpu/lib/ld-musl-x86_64.so.1 \
  --library-path /usr/lib/plexmediaserver/lib:/vaapi-amdgpu/lib \
  "/usr/lib/plexmediaserver/Plex Transcoder.real" "$@"
```

Plex's binaries are built against musl 1.2.2, and musl is forward-compatible, so running them on
1.2.5 is the safe direction. Only the transcoder is wrapped — it is the only process that loads the
VA driver, which keeps the blast radius minimal.

`--library-path` lists Plex's own library directory **first** because musl searches it before
`DT_RPATH`; Plex's libraries must keep winning over the Alpine ones in the payload.

### Why the wrapper is installed at runtime

The image is `FROM plexinc/pms-docker:public`, which reinstalls Plex over
`/usr/lib/plexmediaserver` at every container start. Anything patched into that directory at build
time is discarded, so the wrapper has to be reapplied by an init hook that runs after
`50-plex-update`. The hook is idempotent and fails soft in every branch: a server that transcodes
on the CPU is a working server, one that will not start is not.

## Why no `LD_LIBRARY_PATH`

`LD_LIBRARY_PATH` is global to the container. The base image is Ubuntu, and Plex's own startup
scripts run `bash`, `curl`, `xmlstarlet` and `dpkg` — all glibc binaries. Pointing
`LD_LIBRARY_PATH` at a directory full of musl-linked `libz.so.1` and `libstdc++.so.6` breaks them.

Instead every library in the payload gets `RPATH=$ORIGIN` (and `$ORIGIN:$ORIGIN/..` for
`libgallium`, since `libva` dlopens the driver through the `dri/` symlink and musl expands `$ORIGIN`
from that path without resolving it), and the wrapper passes `--library-path` to the loader, which
is scoped to the transcoder alone.

## The libva version trap

`libva`'s `va_openDriver()` looks for `__vaDriverInit_<major>_<minor>`, counting **down** from its
own minor version. Mesa exports exactly one such symbol, fixed by the libva it was built against.

So a Mesa built against a **newer** libva than Plex ships exports only a higher minor, Plex's libva
never finds an entry point, and the symptom is a silent fall back to CPU transcoding with no error
message anywhere. Today the driver exports `__vaDriverInit_1_22` and Plex ships libva 2.22.0
(VA-API 1.22) — an exact match, but not one to take for granted. Gate 2 asserts it on every build.

## How Plex stays up to date

Nothing in this repo controls it, by design.

`plexinc/pms-docker:public` contains **no** Plex binary; `/etc/cont-init.d/50-plex-update` runs at
every container start, reads `version=public` from `/version.txt`, asks plex.tv for the newest
release on the public channel (which needs no Plex token), and `dpkg -i`s it. This image adds only
`/vaapi-amdgpu` and one init hook, and never touches `/version.txt`, so a Plex upgrade cannot
disturb the driver and the driver cannot pin Plex to an old version.

On the cluster a CronJob restarts the Plex pod nightly, so Plex updates itself daily. This image
inherits that unchanged.

CI therefore only rebuilds for **Mesa and base-image** changes: on push, and weekly. The weekly
build is also a canary — it downloads the *current* Plex release and re-runs the gates, so if a
future Plex bumps musl or libva, CI goes red rather than transcoding silently dropping to CPU.

## Gates

`scripts/gate.sh` runs in its own build stage. None of it needs a GPU.

1. **Relocation** — the driver and its whole closure resolve under the loader we ship. `ldso_fail`
   exits 127 before ldd mode's `exit(0)`, so the exit code is trustworthy. Catches a dependency
   missing from the payload.
2. **libva ABI** — the driver's exported `__vaDriverInit_1_N` must not exceed Plex's libva minor.
3. **Loader version** — the bundled musl must be newer than Plex's. The whole design rests on this;
   if Plex ever catches up, the wrapper stops buying anything and this needs revisiting.

Note what the gates deliberately do **not** claim: relocation is not execution. Constructors run at
`dlopen`, not during a relocation check, which is exactly how the original `SIGSEGV` slipped past a
green gate. Only the hardware test below covers that.

## Building and testing locally

```sh
docker buildx build --target gate .            # the three gates
docker buildx build --load -t plex-amd:test .  # the image
```

## Verifying against real hardware

Plex's ffmpeg is built `--disable-avdevice`, so there is no `lavfi` input — feed it raw NV12
instead. This exercises device access, driver load, constructors and a real encode in one shot:

```sh
dd if=/dev/urandom of=/tmp/in.nv12 bs=1382400 count=30      # 30 frames of 1280x720
docker run --rm --device /dev/dri/renderD128 -v /tmp:/tmp --entrypoint /bin/sh plex-amd:test -c '
  "/usr/lib/plexmediaserver/Plex Transcoder" -hide_banner \
    -f rawvideo -pix_fmt nv12 -s 1280x720 -r 30 -i /tmp/in.nv12 \
    -init_hw_device vaapi=hw:/dev/dri/renderD128 -filter_hw_device hw \
    -vf hwupload -c:v h264_vaapi -f null -'
```

Expect `frame=30` and exit 0. `LIBVA_MESSAGING_LEVEL=2` shows libva's driver search.

Note that `:public` downloads Plex at container start, so `Plex Transcoder` and the wrapper only
exist after the container has run its init scripts once.

## Turning it on

Hardware transcoding is a *server* setting, not a container setting:
**Plex → Settings → Transcoder → "Use hardware acceleration when available"**. Requires Plex Pass.
This image makes it possible; nothing here can enable it.

## Layout

```
Dockerfile                                four stages: plex-ref, mesa, gate, image
scripts/collect-libs.sh                   DT_NEEDED closure, the musl loader, RPATH
scripts/gate.sh                           the three compatibility gates
root/etc/cont-init.d/55-vaapi-transcoder  wraps the transcoder at every start
.github/workflows/build.yml               push + weekly build to ghcr.io
```
