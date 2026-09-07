#!/usr/bin/env bash
set -euo pipefail

# generate-samples.sh — Render the theme and look samples the README embeds
#
# One container per sample, because a setting is read once at startup and
# cannot change while the hook is listening — the same reason test-image.sh
# starts three. Driving it through the environment rather than a per-block
# `init` directive is what makes a sample show what the setting produces.
#
# Renders through the raster path, so a sample is the picture a PDF gets.
#
# Usage: make samples
#
# Exit codes:
#   0 - Every sample rendered
#   1 - A container never bound its socket, or a render failed

REPO_ROOT="$(cd "$(dirname "${0}")/.." && pwd)"
IMAGE_TAG="${IMAGE_TAG:-keystone-hook-diagrams:local}"
OUT_DIR="${REPO_ROOT}/docs/samples"

SOCKET="/hooks/samples.sock"

# Exercises what a palette actually colors: node fill, node border, the decision
# shape, edge strokes and edge labels. A flowchart small enough to stay legible
# at the width a README table cell gives it.
readonly DIAGRAM='flowchart LR
    A[Draft] --> B{Review}
    B -->|approved| C[Published]
    B -->|changes| A'

CONTAINERS=()
VOLUMES=()

cleanup() {
  local name
  for name in ${CONTAINERS[@]+"${CONTAINERS[@]}"}; do
    docker rm -f "${name}" > /dev/null 2>&1 || true
  done
  for name in ${VOLUMES[@]+"${VOLUMES[@]}"}; do
    docker volume rm "${name}" > /dev/null 2>&1 || true
  done
}
trap cleanup EXIT

wait_for_socket() {
  local name="${1}"
  local attempt=0

  while [[ "${attempt}" -lt 90 ]]; do
    if docker exec "${name}" test -S "${SOCKET}" > /dev/null 2>&1; then
      return 0
    fi
    sleep 1
    attempt=$((attempt + 1))
  done

  echo "FAIL: ${name} never bound ${SOCKET}" >&2
  docker logs "${name}" >&2 || true
  return 1
}

# Renders one sample. The PNG comes back over stdout rather than a file: the
# root is read-only, /tmp is a tmpfs and `docker cp` cannot read one, and a
# bind-mounted output directory would not be writable by the container's UID.
sample() {
  local slug="${1}"
  shift

  local name="ks-sample-${slug}-$$"
  CONTAINERS+=("${name}")
  VOLUMES+=("${name}-hooks")

  docker run -d --name "${name}" \
    --read-only \
    --tmpfs /tmp \
    -e HOME=/tmp \
    -e HOOK_SOCKET="${SOCKET}" \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --network none \
    -v "${name}-hooks:/hooks" \
    ${@+"${@}"} \
    "${IMAGE_TAG}" > /dev/null

  wait_for_socket "${name}"

  docker exec -e DIAGRAM="${DIAGRAM}" "${name}" node -e '
    const net = require("node:net");
    const request = JSON.stringify({
      op: "transform",
      format: "pdf",
      content: process.env.DIAGRAM,
    });
    const socket = net.connect(process.env.HOOK_SOCKET, () => socket.end(request));
    let body = "";
    socket.on("data", (chunk) => (body += chunk));
    socket.on("end", () => {
      const reply = JSON.parse(body);
      if (reply.error) {
        process.stderr.write(reply.error + "\n");
        process.exit(1);
      }
      process.stdout.write(Buffer.from(reply.assets[0].data, "base64"));
    });' > "${OUT_DIR}/${slug}.png"

  docker rm -f "${name}" > /dev/null
  docker volume rm "${name}-hooks" > /dev/null 2>&1 || true

  local size
  size="$(wc -c < "${OUT_DIR}/${slug}.png" | tr -d ' ')"
  echo "  ${slug}.png  ${size} bytes"
}

mkdir -p "${OUT_DIR}"

echo "Rendering samples with ${IMAGE_TAG} ..."

for theme in default base dark forest neutral; do
  sample "theme-${theme}" -e "KEYSTONE_DIAGRAMS_THEME=${theme}"
done

# The look axis, held against theme-default: the only setting that differs.
sample "look-hand-drawn" -e "KEYSTONE_DIAGRAMS_LOOK=handDrawn"

echo "OK  ${OUT_DIR}"
