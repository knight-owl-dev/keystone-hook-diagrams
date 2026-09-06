#!/usr/bin/env bash
set -euo pipefail

# validate-trivy-pins.sh — Validate that the Trivy scanner version matches
# across every call site.
#
# trivy.yaml lists the call sites and the tag shape each one takes. Two failure
# modes justify the check: a bare GitHub tag 404s in trivy's install.sh, and an
# absent workflow pin leaves trivy-action installing its own bundled version.
#
# Usage:
#   scripts/lib/validate-trivy-pins.sh
#
# Exit codes:
#   0 - Every pin present, correctly prefixed, and equal
#   1 - A pin missing, wrongly prefixed, or drifted

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

makefile="${REPO_ROOT}/Makefile"
workflows=(
  "${REPO_ROOT}/.github/workflows/publish.yml"
  "${REPO_ROOT}/.github/workflows/cve-monitor.yml"
)

errors=0
fail() {
  echo "$1" >&2
  errors=1
}

# Docker tag from the Makefile — bare.
matches="$(sed -n 's|^.*aquasec/trivy:\([^ "]*\).*$|\1|p' "${makefile}")"
make_pin="${matches%%$'\n'*}"

if [[ -z "${make_pin}" ]]; then
  fail "Makefile: no aquasec/trivy:<version> pin found"
elif [[ "${make_pin}" == v* ]]; then
  fail "Makefile: Docker tag must be bare, got 'aquasec/trivy:${make_pin}'"
fi

expected="${make_pin#v}"

# GitHub release tag from each trivy-action step — v-prefixed.
for workflow in "${workflows[@]}"; do
  name="$(basename "${workflow}")"

  if [[ ! -f "${workflow}" ]]; then
    fail "${name}: workflow not found"
    continue
  fi

  pins="$(
    yq -r '.jobs[].steps[]?
      | select(.uses // "" | test("^aquasecurity/trivy-action@"))
      | .with.version // "MISSING"' "${workflow}"
  )"

  if [[ -z "${pins}" ]]; then
    fail "${name}: no aquasecurity/trivy-action step found"
    continue
  fi

  while IFS= read -r pin; do
    if [[ "${pin}" == "MISSING" ]]; then
      fail "${name}: trivy-action step has no 'version:' — it would install the action's own default"
    elif [[ "${pin}" != v* ]]; then
      fail "${name}: release tag must be v-prefixed, got 'version: ${pin}'"
    elif [[ "${pin#v}" != "${expected}" ]]; then
      fail "${name}: pinned to '${pin}', Makefile pins '${expected}'"
    fi
  done <<< "${pins}"
done

[[ "${errors}" -eq 0 ]] || exit 1
