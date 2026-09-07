# Plex Transcoder segfaults with `-copyts` + `h264_vaapi` on AMD VCN 3 (Raphael iGPU)

## Summary

On an AMD Raphael/Granite Ridge iGPU, `Plex Transcoder` crashes with `SIGSEGV` whenever a hardware
VAAPI encode is combined with `-copyts`. Plex adds `-copyts` to every segmented streaming session, so
**every** hardware transcode attempt dies within about half a second, and Plex silently falls back to
software. The server keeps working; it just never actually uses the GPU, and the client shows a plain
"Transcode" with no `(hw)`.

Without `-copyts` the identical pipeline hardware-encodes correctly at every output resolution up to
4K, so the GPU, driver and VAAPI stack are all functional.

This reproduces with **Plex's own downloaded VA driver** (`rsv-…-linux-x86_64`), so it is not caused
by a substituted Mesa.

## Environment

| | |
|---|---|
| Plex Media Server | 1.43.3.10896-cb3ebc72d |
| Image | `plexinc/pms-docker:public` (Ubuntu 24.04 base), unmodified |
| Host OS | Talos Linux, kernel 6.18.5 |
| GPU | AMD Radeon Graphics (Raphael / Granite Ridge), PCI `1002:13c0`, VCN 3.x |
| GPU passthrough | VFIO to a VM; `/dev/dri/renderD128` present in the container |
| VA-API | 1.22 (Plex's bundled libva 2.22.0) |
| VA driver | Plex's own `rsv-2dfba56244514cf73d4bbc0c-linux-x86_64` |
| Hardware transcoding | enabled, Plex Pass active |

`vainfo` against this GPU reports `VAProfileH264Main : VAEntrypointVLD, VAEntrypointEncSlice`, so
H.264 encode is supported.

## Symptom as seen by the server

Plex decides on hardware, starts the job, and it dies:

```
DEBUG - [Req#2717/Transcode] TPU: hardware transcoding: using hardware decode accelerator vaapi
DEBUG - [Req#2717/Transcode] TPU: hardware transcoding: zero-copy support present
DEBUG - [Req#2717/Transcode] Codecs: hardware transcoding: testing API vaapi for device
        '/dev/dri/renderD128' (AMD Granite Ridge [Radeon Graphics])
INFO  - [Req#2717/Transcode] Preparing driver rsv for GPU AMD Granite Ridge [Radeon Graphics]
DEBUG - [Req#2717/Transcode] TPU: hardware transcoding: final decoder: vaapi, final encoder: vaapi
DEBUG - [Req#2717/Transcode/JobRunner] Jobs: Starting child process with pid 1648
...
DEBUG - Jobs: '/usr/lib/plexmediaserver/Plex Transcoder' exit code for process 1648 is -11 (signal: Segmentation fault)
```

Roughly 0.5 s later Plex re-plans without hardware and starts a software job:

```
DEBUG - TPU: hardware transcoding: enabled, but no hardware decode accelerator found
DEBUG - Codecs: hardware transcoding: testing API vaapi for device '' ()
DEBUG - TPU: hardware transcoding: final decoder: , final encoder:
```

That second evaluation reports an **empty** device, which is misleading — the device is fine; the
first job crashed. This is what makes the failure hard to diagnose from the logs alone: the
successful hardware decision is right there, so it looks like hardware transcoding is working.

Kernel log for the crashed process:

```
Plex Transcoder[…]: segfault at 54 ip …37c error 4 in libavformat.so.60[19637c,…]
Plex Transcoder[…]: segfault at 18 ip …d33 error 4 in libavcodec.so.60[4f2d33,…]
```

Both are null-pointer dereferences (`error 4` = user-mode read of a non-present page) inside Plex's
bundled ffmpeg, at a fixed offset in each library.

## Minimal reproduction

Run inside the container. `FFMPEG_EXTERNAL_LIBS` and `LIBVA_DRIVERS_PATH` are set exactly as Plex
sets them for its own jobs (take the values from a `Job running:` line in the server log).

```sh
T="/usr/lib/plexmediaserver/Plex Transcoder"
F="/path/to/any/h264/file.mkv"
export FFMPEG_EXTERNAL_LIBS="/config/Library/Application Support/Plex Media Server/Codecs/<build>-linux-x86_64/"
export LIBVA_DRIVERS_PATH="/config/Library/Application Support/Plex Media Server/Cache/va-dri-linux-x86_64"

"$T" -hide_banner -nostats -loglevel quiet \
  -codec:0 h264 -hwaccel:0 vaapi -hwaccel_output_format:0 vaapi -hwaccel_device:0 vaapi \
  -ss 120 -i "$F" -start_at_zero -copyts \
  -init_hw_device vaapi=vaapi:/dev/dri/renderD128 -filter_hw_device vaapi -t 4 \
  -filter_complex "[0:0]hwupload[0];[0]scale_vaapi=w=1920:h=804:format=nv12[1];[1]hwupload[2]" \
  -map "[2]" -codec:0 h264_vaapi -b:0 8000k -f null -
echo "exit=$?"     # 139 = SIGSEGV
```

Removing `-copyts` from that same command makes it succeed.

## Isolation

Everything below is one variable changed at a time, judged by process exit code (139 = SIGSEGV), not
by log text.

**The trigger is `-copyts`.** Same source, same filter chain, same encoder:

| flags | result |
|---|---|
| neither | OK |
| `-start_at_zero` | OK |
| **`-copyts`** | **SIGSEGV** |
| `-start_at_zero -copyts` (what Plex sends) | **SIGSEGV** |

**Not the resolution.** With `-copyts`, every output size crashes; without it, every output size
works — 1280x536, 1920x804, 2560x1072, 3840x1608, and synthetic input up to 3840x2160.

**Not hardware decode.** Software decode plus `h264_vaapi` encode crashes identically.

**Not the VA driver.** Crashes the same with Plex's own downloaded `rsv-…` driver and with Alpine's
Mesa 25.1.9.

**Not the container's libc.** The host image here normally substitutes a newer musl; the crash
reproduces with Plex's own bundled musl 1.2.2 and Plex's unmodified `lib/` directory, invoked
directly through Plex's own loader.

**Not the muxer or bitstream filter on their own.** They are neither necessary nor sufficient:
`-copyts` with `-f null` and no `-bsf` still crashes, and the full segment-muxer pipeline without
`-copyts` succeeds.

**Software transcoding of the same file is unaffected** and runs indefinitely.

## Impact

Hardware transcoding is unusable on this GPU for normal playback, because Plex always adds `-copyts`
for segmented streaming. The failure is silent — Plex reports a hardware decision, falls back after
the crash, and the only visible symptoms are missing `(hw)` in the dashboard and high CPU. Each
playback start also costs a crashed process and about half a second.

## What would help

- Whether `-copyts` is required for the HLS segment path when the encoder is VAAPI, or whether it can
  be omitted or replaced.
- Whether the null dereference is in Plex's ffmpeg patches or in upstream's VAAPI encoder timestamp
  handling — the fixed offsets (`libavcodec.so.60+0x4f2d33`, `libavformat.so.60+0x19637c`) should
  identify it directly against the build's symbols.
- If it is useful, the fallback path reporting `device '' ()` after a crashed hardware job is
  independently worth changing: it reads as a device-detection failure and sends anyone debugging
  this in entirely the wrong direction.
