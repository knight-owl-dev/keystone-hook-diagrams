# keystone-hook-diagrams — Renders mermaid fences in a Keystone book.
#
# A Keystone hook: it owns a Unix socket, answers `describe` and `transform`,
# and shares nothing with the engine. See
# https://keystone.knight-owl.dev/engine/writing-a-hook/
#
# Node owns the socket rather than socat, so one Chromium starts with the
# container and serves every request. Every block waits on this hook, so paying
# a browser launch per diagram would spend the author's whole timeout on
# process startup.

# ---------- dependencies ----------
# The only stage that needs a package manager. Nothing from here reaches the
# final image except the tree npm resolves and the node binary itself.
FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS deps

WORKDIR /app

# No version ARGs: package-lock.json pins the whole tree with integrity hashes,
# and `npm ci` refuses a manifest that disagrees with it. `make resolve`
# regenerates both files.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# ---------- runtime ----------
# Alpine rather than node:22-alpine: that image carries npm, npx, yarn and
# corepack, which a service running only `node src/server.js` never calls. Each
# brings a vendored dependency tree that every CVE scan then reports. Copying
# the node binary out keeps the pinned runtime without them.
#
# The two digests are coupled: node is linked against this Alpine's musl, so
# bumping one without the other risks an ABI mismatch. node:22-alpine is built
# on Alpine 3.24, which is what the tag below tracks.
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

# Chromium from the distro: puppeteer-core drives a browser, it does not ship
# one, and a distro build is what gets the security updates.
#
# The font packages are contract, not incidental: the manual names what
# KEYSTONE_DIAGRAMS_FONT can resolve, so opensans is asked for by name rather
# than relied on as something another package happens to pull in.
#
# libstdc++ and libgcc are what the copied node binary links against; chromium
# would pull them anyway, but this image does not depend on that.
#
# The floored packages are chromium's own dependencies, named here only to
# raise them. `apk add` on an already-installed package is a no-op, so a
# transitive dependency is otherwise whatever the cached layer resolved. The
# layer key is this command, so a registry cache keeps serving that build until
# the string changes — the floor is both the fix and the cache bust. `>=` keeps
# it working when the repository moves on. Drop each once the base ships it.
#   libcrypto3, libssl3            CVE-2026-14456
#   libblkid, libmount, libuuid    CVE-2026-53612 and 20 more in util-linux
#
# DL3018: the rest are unpinned on purpose. Alpine keeps only the current build
# of a package, so an exact version breaks the build instead of holding it
# still.
# hadolint ignore=DL3018
RUN apk add --no-cache chromium nss freetype harfbuzz ca-certificates \
    libstdc++ libgcc font-noto font-opensans \
    "libcrypto3>=3.5.8-r0" "libssl3>=3.5.8-r0" \
    "libblkid>=2.42.3-r1" "libmount>=2.42.3-r1" "libuuid>=2.42.3-r1"

COPY --from=deps /usr/local/bin/node /usr/local/bin/node
COPY --from=deps /app/node_modules /app/node_modules
COPY src /app/src

ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser \
    PUPPETEER_SKIP_DOWNLOAD=true

# The socket directory ships with the image so a volume mounted over it
# inherits this mode. Whichever container mounts an empty volume first decides
# its ownership, and the hook starts before the engine — so left to Docker the
# volume would arrive root-owned and the bind would fail.
RUN mkdir -p /hooks && chmod 1777 /hooks

# Non-root: this image owns no workspace, only a volume it shares with the
# engine. The 1777 above is what lets a non-root UID own the socket.
RUN addgroup -g 1001 -S hook && adduser -u 1001 -S -G hook hook
USER 1001:1001

# ---------- metadata ----------
ARG IMAGE_VERSION=local

# server.js reads this back at runtime; an ARG does not reach the process.
ENV IMAGE_VERSION=${IMAGE_VERSION}

LABEL maintainer="Knight Owl <support@knight-owl.dev>"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.authors="Knight Owl LLC"
LABEL org.opencontainers.image.source="https://github.com/knight-owl-dev/keystone-hook-diagrams"
LABEL org.opencontainers.image.version="${IMAGE_VERSION}"
LABEL org.opencontainers.image.description="Mermaid diagram rendering hook for Keystone"

# No HEALTHCHECK on purpose: the readiness test is the socket, and HOOK_SOCKET
# names it from outside. The caller that sets the variable declares the matching
# check. See the README for what that check has to cover.

ENTRYPOINT ["node", "/app/src/server.js"]
