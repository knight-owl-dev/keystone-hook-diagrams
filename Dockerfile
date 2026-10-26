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
# final image except the tree npm resolves.
#
# The tree is pure JavaScript, so its Node need not match the runtime's. A
# native module would: it has to build on node-chromium's Node line and musl.
FROM node:26-alpine3.24@sha256:40cd011b55415bc894e45b02fdd5a5dfde056921b7d23a64c74f80497af48797 AS deps

WORKDIR /app

# No version ARGs: package-lock.json pins the whole tree with integrity hashes,
# and `npm ci` refuses a manifest that disagrees with it. `make resolve`
# regenerates both files.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# ---------- runtime ----------
# Node, Chromium and the fonts, from devops. Alpine cannot pin a package, so
# the digest is what freezes them: every build, local or CI, renders with the
# same bytes, which the render corpus's lockfile depends on. A CVE in them is
# fixed there and arrives as a digest bump.
FROM ghcr.io/knight-owl-dev/node-chromium:v1.7.0@sha256:2bb4332882e4f7f5f633a8763e7e46706ec8190f2aaae2d2d9f8da387c79c956

COPY --from=deps /app/node_modules /app/node_modules
COPY src /app/src

ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser

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
