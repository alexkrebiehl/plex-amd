# Plex Media Server with a working AMD VAAPI driver.
#
# The official image ships no VA driver at all, so this adds Mesa's radeonsi
# driver - and the musl loader it needs - as a self-contained payload under
# /vaapi-amdgpu. See README.md for why the loader is the crux.

# ---------------------------------------------------------------------------
# 1. Plex's loader and libva, for the compatibility gates only. Never shipped.
#    A ":public" image has no Plex binary at build time, so the gates need the
#    real thing from the current release.
# ---------------------------------------------------------------------------
FROM alpine:3.22 AS plex-ref
RUN apk add --no-cache curl tar xz binutils
RUN set -eux; \
    curl -fsSL "https://plex.tv/api/downloads/5.json" -o /tmp/dl.json; \
    url=$(grep -o 'https://[^"]*/debian/plexmediaserver_[^"]*_amd64\.deb' /tmp/dl.json | head -1); \
    test -n "$url"; \
    echo "Plex reference build: $url"; \
    curl -fsSL "$url" -o /tmp/pms.deb; \
    cd /tmp && ar x pms.deb data.tar.xz && tar xf data.tar.xz; \
    mkdir -p /plex; \
    cp usr/lib/plexmediaserver/lib/ld-musl-x86_64.so.1 \
       usr/lib/plexmediaserver/lib/libva.so.2 /plex/

# ---------------------------------------------------------------------------
# 2. The Mesa payload, plus the musl loader Mesa was built against.
# ---------------------------------------------------------------------------
FROM alpine:3.22 AS mesa
RUN apk add --no-cache mesa-va-gallium patchelf binutils
COPY scripts/collect-libs.sh /tmp/
RUN /tmp/collect-libs.sh /vaapi-amdgpu

# ---------------------------------------------------------------------------
# 3. Gates. Built explicitly by CI with --target gate so a compatibility failure
#    is its own clearly-named step rather than a puzzling error in the final
#    image build. Nothing below references this stage, so a plain build skips it.
# ---------------------------------------------------------------------------
FROM alpine:3.22 AS gate
RUN apk add --no-cache binutils
COPY --from=plex-ref /plex /plex
COPY --from=mesa /vaapi-amdgpu /vaapi-amdgpu
COPY scripts/gate.sh /tmp/
RUN /tmp/gate.sh

# ---------------------------------------------------------------------------
# 4. The image.
# ---------------------------------------------------------------------------
FROM plexinc/pms-docker:public

LABEL org.opencontainers.image.source="https://github.com/alexkrebiehl/plex-amd" \
      org.opencontainers.image.description="Plex Media Server with Mesa's AMD VAAPI driver" \
      org.opencontainers.image.licenses="MIT"

COPY --from=mesa /vaapi-amdgpu /vaapi-amdgpu
# libdrm_amdgpu reads this from a path fixed at its compile time.
COPY --from=mesa /vaapi-amdgpu/share/libdrm/amdgpu.ids /usr/share/libdrm/amdgpu.ids

# Wraps "Plex Transcoder" so it runs under the payload's musl. Must happen at
# every container start, not here: 50-plex-update reinstalls Plex over
# /usr/lib/plexmediaserver on every start, discarding anything patched in at
# build time.
COPY root/ /
RUN chmod 0755 /etc/cont-init.d/55-vaapi-transcoder \
 && test -x /vaapi-amdgpu/lib/ld-musl-x86_64.so.1 \
 && test -e /vaapi-amdgpu/lib/dri/radeonsi_drv_video.so

# Where Plex's libva looks for the driver. Set here rather than in the wrapper
# so it also applies if the transcoder is invoked by hand.
#
# LD_LIBRARY_PATH is deliberately NOT set: it is global to the container, and
# Ubuntu's glibc tooling - bash, curl, xmlstarlet and dpkg, all of which Plex's
# own startup scripts use - would pick up these musl-linked libz.so.1 and
# libstdc++.so.6 and break. The wrapper passes --library-path to the loader
# instead, which is scoped to the transcoder alone.
ENV LIBVA_DRIVERS_PATH=/vaapi-amdgpu/lib/dri
