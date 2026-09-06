#!/usr/bin/env bats
# shellcheck shell=bash
#
# Tests for scripts/lib/validate-trivy-pins.sh — the gate that keeps the Trivy
# scanner version equal across the Makefile and both scanning workflows. Each
# test builds a minimal fake repo under BATS_TEST_TMPDIR holding a Makefile and
# the two workflows, then runs the script against it.
#
# REPO_ROOT inside the script is derived from its own path, so we symlink the
# real scripts/lib into the fake repo.

load ../../helpers/common

setup() {
  common_setup
  FAKE_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${FAKE_REPO}/scripts" "${FAKE_REPO}/.github/workflows"
  ln -s "${REPO_ROOT}/scripts/lib" "${FAKE_REPO}/scripts/lib"
  SCRIPT="${FAKE_REPO}/scripts/lib/validate-trivy-pins.sh"
  export SCRIPT FAKE_REPO
}

_make_makefile() { printf 'TRIVY_IMAGE := aquasec/trivy:%s\n' "$1" > "${FAKE_REPO}/Makefile"; }

# _make_workflow <name> [version] — an empty version omits the `version:` input.
_make_workflow() {
  local name="$1" version="${2-}"
  {
    echo "jobs:"
    echo "  scan:"
    echo "    steps:"
    echo "      - uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25"
    echo "        with:"
    echo "          image-ref: example:latest"
    if [[ -n "${version}" ]]; then
      echo "          version: ${version}"
    fi
  } > "${FAKE_REPO}/.github/workflows/${name}.yml"
}

# Both workflows pinned identically unless a test overrides one.
_make_workflows() {
  _make_workflow publish "$1"
  _make_workflow cve-monitor "$1"
}

# ── happy path ───────────────────────────────────────────────────────

@test "exits 0 when the Makefile and both workflows pin the same version" {
  _make_makefile "0.73.0"
  _make_workflows "v0.73.0"
  run "${SCRIPT}"
  assert_success
  assert_output ""
}

# ── drift ────────────────────────────────────────────────────────────

@test "exits 1 and names both versions when a workflow drifts from the Makefile" {
  _make_makefile "0.73.0"
  _make_workflow publish "v0.73.0"
  _make_workflow cve-monitor "v0.70.0"
  run "${SCRIPT}"
  assert_failure 1
  assert_output --partial "cve-monitor.yml: pinned to 'v0.70.0', Makefile pins '0.73.0'"
}

@test "reports every drifted workflow, not just the first" {
  _make_makefile "0.73.0"
  _make_workflows "v0.70.0"
  run "${SCRIPT}"
  assert_failure 1
  assert_output --partial "publish.yml: pinned to 'v0.70.0'"
  assert_output --partial "cve-monitor.yml: pinned to 'v0.70.0'"
}

# ── prefix rules ─────────────────────────────────────────────────────

@test "exits 1 when a workflow pin lacks the v prefix" {
  _make_makefile "0.73.0"
  _make_workflow publish "0.73.0"
  _make_workflow cve-monitor "v0.73.0"
  run "${SCRIPT}"
  assert_failure 1
  assert_output --partial "publish.yml: release tag must be v-prefixed"
}

@test "exits 1 when the Makefile Docker tag carries a v prefix" {
  _make_makefile "v0.73.0"
  _make_workflows "v0.73.0"
  run "${SCRIPT}"
  assert_failure 1
  assert_output --partial "Makefile: Docker tag must be bare"
}

# ── missing pins ─────────────────────────────────────────────────────

@test "exits 1 when a trivy-action step omits version, which would use the action default" {
  _make_makefile "0.73.0"
  _make_workflow publish ""
  _make_workflow cve-monitor "v0.73.0"
  run "${SCRIPT}"
  assert_failure 1
  assert_output --partial "publish.yml: trivy-action step has no 'version:'"
}

@test "exits 1 when a workflow has no trivy-action step at all" {
  _make_makefile "0.73.0"
  _make_workflow publish "v0.73.0"
  printf 'jobs:\n  scan:\n    steps:\n      - run: echo hi\n' \
    > "${FAKE_REPO}/.github/workflows/cve-monitor.yml"
  run "${SCRIPT}"
  assert_failure 1
  assert_output --partial "cve-monitor.yml: no aquasecurity/trivy-action step found"
}

@test "exits 1 when the Makefile has no trivy image pin" {
  printf 'all:\n\t@echo hi\n' > "${FAKE_REPO}/Makefile"
  _make_workflows "v0.73.0"
  run "${SCRIPT}"
  assert_failure 1
  assert_output --partial "Makefile: no aquasec/trivy:<version> pin found"
}

@test "exits 1 when a workflow file is missing" {
  _make_makefile "0.73.0"
  _make_workflow publish "v0.73.0"
  run "${SCRIPT}"
  assert_failure 1
  assert_output --partial "cve-monitor.yml: workflow not found"
}
