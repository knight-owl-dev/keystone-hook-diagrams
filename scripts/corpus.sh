#!/usr/bin/env bash
set -euo pipefail

# corpus.sh — Render the corpus and write or check its lockfile
#
# Every source in tests/corpus is drawn at each layout under the house style.
# review.mmd is also drawn at every theme and look. Each render is an SVG,
# what EPUB gets, and a PNG, what PDF gets; the lockfile holds one hash per
# render.
#
# One container per setting, since a setting is read once at startup. The
# environment drives it, as a project's config would, so a render shows what
# the setting produces.
#
# Usage: scripts/corpus.sh write|check [OUT_DIR]
#
# OUT_DIR keeps the renders, which CI uploads and publish deploys; without it
# they go to a temporary directory.
#
# Exit codes:
#   0 - Rendered; under `check`, every hash matched the lockfile
#   1 - A container never bound its socket, a render failed, or a hash drifted

export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${0}")/.." && pwd)"
IMAGE_TAG="${IMAGE_TAG:-keystone-hook-diagrams:local}"
CORPUS_DIR="${REPO_ROOT}/tests/corpus"
LOCKFILE="${CORPUS_DIR}/renders.sha256"

MODE="${1:-}"
OUT_DIR="${2:-}"

SOCKET="/hooks/corpus.sock"

LAYOUTS=(dagre elk)
THEMES=(default base dark forest neutral)

# The diagram every theme and look is drawn with: it exercises node fill and
# border, the decision shape, edge strokes and edge labels.
STRIP="review"

# What each format is asked for under, and the extension its asset carries.
FORMATS=(epub:svg pdf:png)

case "${MODE}" in
  write | check) ;;
  *)
    echo "usage: ${0} write|check [OUT_DIR]" >&2
    exit 1
    ;;
esac

CONTAINERS=()
VOLUMES=()
TMP_DIR=""

cleanup() {
  local name

  if [[ -n "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
  for name in ${CONTAINERS[@]+"${CONTAINERS[@]}"}; do
    docker rm -f "${name}" > /dev/null 2>&1 || true
  done
  for name in ${VOLUMES[@]+"${VOLUMES[@]}"}; do
    docker volume rm "${name}" > /dev/null 2>&1 || true
  done
}
trap cleanup EXIT

if [[ -z "${OUT_DIR}" ]]; then
  TMP_DIR="$(mktemp -d)"
  OUT_DIR="${TMP_DIR}"
fi
mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"

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

# Paths of every render, in the order drawn. The order is fixed by the loops
# and the C-locale glob, so the lockfile needs no sort.
RENDERS=()

# Renders the named sources under one setting, into <layout>/<setting>/.
setting() {
  local layout="${1}"
  local slug="${2}"
  local sources="${3}"
  shift 3

  local name="ks-corpus-${layout}-${slug}-$$"
  CONTAINERS+=("${name}")
  VOLUMES+=("${name}-hooks")

  docker run -d --name "${name}" \
    --read-only \
    --tmpfs /tmp \
    -e HOME=/tmp \
    -e HOOK_SOCKET="${SOCKET}" \
    -e KEYSTONE_DIAGRAMS_LAYOUT="${layout}" \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --network none \
    -v "${name}-hooks:/hooks" \
    -v "${REPO_ROOT}/tests:/tests:ro" \
    ${@+"${@}"} \
    "${IMAGE_TAG}" > /dev/null

  wait_for_socket "${name}"
  mkdir -p "${OUT_DIR}/${layout}/${slug}"

  local source pair format ext path
  for source in ${sources}; do
    for pair in "${FORMATS[@]}"; do
      format="${pair%%:*}"
      ext="${pair##*:}"
      path="${layout}/${slug}/${source}.${ext}"
      docker exec "${name}" node /tests/render.js \
        "/tests/corpus/${source}.mmd" "${format}" > "${OUT_DIR}/${path}"
      RENDERS+=("${path}")
    done
  done

  docker rm -f "${name}" > /dev/null
  docker volume rm "${name}-hooks" > /dev/null 2>&1 || true
  echo "  ${layout}/${slug}"
}

ALL_SOURCES=""
for file in "${CORPUS_DIR}"/*.mmd; do
  ALL_SOURCES+="$(basename "${file}" .mmd) "
done

echo "Rendering the corpus with ${IMAGE_TAG} ..."

for layout in "${LAYOUTS[@]}"; do
  setting "${layout}" house "${ALL_SOURCES}"
  for theme in "${THEMES[@]}"; do
    setting "${layout}" "theme-${theme}" "${STRIP}" \
      -e "KEYSTONE_DIAGRAMS_THEME=${theme}"
  done
  setting "${layout}" look-hand-drawn "${STRIP}" \
    -e "KEYSTONE_DIAGRAMS_LOOK=handDrawn"
done

hashes="$(cd "${OUT_DIR}" && shasum -a 256 "${RENDERS[@]}")"

if [[ "${MODE}" == "write" ]]; then
  printf '%s\n' "${hashes}" > "${LOCKFILE}"
  echo "OK  ${#RENDERS[@]} renders written to ${LOCKFILE#"${REPO_ROOT}/"}"
  exit 0
fi

if ! drift="$(diff -u "${LOCKFILE}" - <<< "${hashes}")"; then
  echo "${drift}" >&2
  echo "FAIL: renders differ from ${LOCKFILE#"${REPO_ROOT}/"}; run make corpus and commit it" >&2
  exit 1
fi

echo "OK  ${#RENDERS[@]} renders match ${LOCKFILE#"${REPO_ROOT}/"}"
