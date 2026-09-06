#!/usr/bin/env bash
set -euo pipefail

# test-image.sh — Integration test for the keystone-hook-diagrams image
#
# This script owns the container lifecycle; probe.js does the asking, over the
# socket, from inside. It runs on the host because the in-container path does
# not fit: no bash, an ENTRYPOINT that owns argv, and nothing to interrogate —
# a hook is tested by whether it renders.
#
# Three containers, because a diagnostic is decided by the environment the hook
# started with and cannot change once it is listening.
#
# Usage: make test-image
#
# Exit codes:
#   0 - The hook describes and renders correctly
#   1 - A check failed, or a container never became healthy

REPO_ROOT="$(cd "$(dirname "${0}")/.." && pwd)"
IMAGE_TAG="${IMAGE_TAG:-keystone-hook-diagrams:local}"

# Deliberately not the name the template passes. The socket's name belongs to the
# caller, so verifying under a different one is what catches a default baked back
# into the image or the probe.
SOCKET="/hooks/ks-verify.sock"

# One family the image carries and one it does not. The pair is what makes the
# font packages a contract, since the manual tells authors which families
# KEYSTONE_DIAGRAMS_FONT can resolve.
PRESENT_FONT="Open Sans"
ABSENT_FONT="Nonexistent Sans"

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

# Waits on the healthcheck declared below, which the image no longer carries:
# it does not own the socket's name and so cannot test for it.
wait_healthy() {
  local name="${1}"
  local status=""
  local attempt=0

  while [[ "${attempt}" -lt 90 ]]; do
    status="$(docker inspect --format '{{.State.Health.Status}}' "${name}" 2> /dev/null || true)"
    case "${status}" in
      healthy) return 0 ;;
      unhealthy) break ;;
    esac
    sleep 1
    attempt=$((attempt + 1))
  done

  echo "FAIL: ${name} never became healthy (last status: ${status:-unknown})" >&2
  docker logs "${name}" >&2 || true
  return 1
}

# Runs under the template's own constraints, so what passes here is what the
# image meets in production. A Chromium that started writing outside HOME would
# otherwise launch fine under verify and fail to start in a book build.
#
# /hooks is a volume because a read-only root cannot be written to, which is
# also why the template mounts one there.
probe() {
  local mode="${1}"
  shift

  local name="ks-hook-verify-${mode}-$$"
  CONTAINERS+=("${name}")
  VOLUMES+=("${name}-hooks")

  # The healthcheck rides along with HOOK_SOCKET because the two are one
  # decision. The intervals are the template's, so what passes here is what the
  # image meets in production; the README says why they are those.
  docker run -d --name "${name}" \
    --read-only \
    --tmpfs /tmp \
    -e HOME=/tmp \
    -e HOOK_SOCKET="${SOCKET}" \
    --health-cmd "test -S ${SOCKET}" \
    --health-interval 30s \
    --health-start-interval 1s \
    --health-start-period 30s \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --network none \
    -v "${name}-hooks:/hooks" \
    -v "${REPO_ROOT}/tests:/tests:ro" \
    ${@+"${@}"} \
    "${IMAGE_TAG}" > /dev/null

  wait_healthy "${name}"
  docker exec "${name}" node /tests/probe.js "${mode}"

  docker rm -f "${name}" > /dev/null
}

# The other half of the contract: with no name to bind, the hook says so rather
# than choosing one. It stops before Chromium, so this needs no volume or tmpfs.
refuses_unnamed_socket() {
  local output=""

  if output="$(docker run --rm --network none "${IMAGE_TAG}" 2>&1)"; then
    echo "FAIL: started with HOOK_SOCKET unset, expected a non-zero exit" >&2
    return 1
  fi

  if [[ "${output}" != *HOOK_SOCKET* ]]; then
    echo "FAIL: refused without naming HOOK_SOCKET: ${output}" >&2
    return 1
  fi

  echo "  OK    refused, naming HOOK_SOCKET"
}

echo "Testing keystone-hook-diagrams (${IMAGE_TAG}) ..."

echo "HOOK_SOCKET unset:"
refuses_unnamed_socket

echo "Protocol and rendering:"
probe render

echo "House style, a font this image carries:"
probe no-diagnostics -e "KEYSTONE_DIAGRAMS_FONT=${PRESENT_FONT}"

echo "House style, a font it does not:"
probe font-warning -e "KEYSTONE_DIAGRAMS_FONT=${ABSENT_FONT}"

echo "OK"
