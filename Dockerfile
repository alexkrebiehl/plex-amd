# Plex Media Server with a working AMD VAAPI driver.
#
# The official image ships no VA driver at all, so this adds Mesa's radeonsi
# driver as a self-contained payload under /vaapi-amdgpu. It deliberately does
# not touch /usr/lib/plexmediaserver, so Plex's own self-update mechanism keeps
# working untouched. See README.md.

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
# 2. The Mesa payload.
# ---------------------------------------------------------------------------
FROM alpine:3.22 AS mesa
RUN apk add --no-cache mesa-va-gallium patchelf binutils gcc musl-dev

COPY shim/plexcompat.c /tmp/
# Supplies the musl >= 1.2.3 symbols Plex's bundled 1.2.2 lacks. -nostdlib keeps
# the shim free of dependencies of its own, so it cannot introduce a new gap.
RUN mkdir -p /vaapi-amdgpu/lib \
 && gcc -shared -fPIC -O2 -fno-stack-protector -nostdlib \
        -Wl,-soname,libplexcompat.so.1 \
        -o /vaapi-amdgpu/lib/libplexcompat.so.1 /tmp/plexcompat.c

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

# The only environment variable needed. LD_LIBRARY_PATH is deliberately NOT set:
# it is global to the container, and Ubuntu's glibc tooling - bash, curl,
# xmlstarlet and dpkg, all of which Plex's own startup scripts use - would pick
# up these musl-linked libz.so.1 and libstdc++.so.6 and break. The payload
# carries RPATH $ORIGIN instead, which resolves the same libraries with no
# blast radius outside the driver.
ENV LIBVA_DRIVERS_PATH=/vaapi-amdgpu/lib/dri
