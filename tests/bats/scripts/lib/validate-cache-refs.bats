#!/usr/bin/env bats
# shellcheck shell=bash
#
# Tests for scripts/lib/validate-cache-refs.sh — the gate that keeps the build
# cache ref equal across the two workflows that write it and the one that reads
# it. Each test builds a minimal fake repo under BATS_TEST_TMPDIR holding the
# three workflows, then runs the script against it.
#
# REPO_ROOT inside the script is derived from its own path, so we symlink the
# real scripts/lib into the fake repo.
#
# Every ref here is single-quoted on purpose: an Actions expression is a literal
# the shell must not expand — hence the file-wide SC2016 directive.
# shellcheck disable=SC2016

load ../../helpers/common

REF='type=registry,ref=ghcr.io/knight-owl-dev/keystone-hook-diagrams:buildcache-${{ matrix.arch }}'

setup() {
  common_setup
  FAKE_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${FAKE_REPO}/scripts" "${FAKE_REPO}/.github/workflows"
  ln -s "${REPO_ROOT}/scripts/lib" "${FAKE_REPO}/scripts/lib"
  SCRIPT="${FAKE_REPO}/scripts/lib/validate-cache-refs.sh"
  export SCRIPT FAKE_REPO
}

# _make_workflow <name> <cache-from> [cache-to] [env-image]
#
# An empty cache-from omits the input; an empty cache-to omits the export. A
# non-empty env-image declares a top-level env.IMAGE, so a test can cover the
# indirection the real workflows use.
_make_workflow() {
  local name="$1" from="${2-}" to="${3-}" image="${4-}"
  {
    if [[ -n "${image}" ]]; then
      echo "env:"
      echo "  IMAGE: ${image}"
    fi
    echo "jobs:"
    echo "  build:"
    echo "    steps:"
    echo "      - uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a"
    echo "        with:"
    echo "          context: ."
    if [[ -n "${from}" ]]; then
      echo "          cache-from: ${from}"
    fi
    if [[ -n "${to}" ]]; then
      echo "          cache-to: ${to}"
    fi
  } > "${FAKE_REPO}/.github/workflows/${name}.yml"
}

# All three workflows agreeing on one inline ref, unless a test overrides one.
_make_workflows() {
  _make_workflow ci "${REF}"
  _make_workflow publish "${REF}" "${REF},mode=max"
  _make_workflow warm-cache "${REF}" "${REF},mode=max"
}

# _write_workflow <name> <body...> — the shapes _make_workflow cannot express.
_write_workflow() {
  local name="$1"
  shift
  printf '%s\n' "$@" > "${FAKE_REPO}/.github/workflows/${name}.yml"
}

# ── happy path ───────────────────────────────────────────────────────

@test "exits 0 when the reader and both writers name the same ref" {
  _make_workflows
  run "${SCRIPT}"
  assert_success
  assert_output ""
}

@test "resolves env.IMAGE, so a file may spell the registry either way" {
  local image='ghcr.io/knight-owl-dev/keystone-hook-diagrams'
  local via_env='type=registry,ref=${{ env.IMAGE }}:buildcache-${{ matrix.arch }}'
  _make_workflow ci "${REF}"
  _make_workflow publish "${via_env}" "${via_env},mode=max" "${image}"
  _make_workflow warm-cache "${via_env}" "${via_env},mode=max" "${image}"
  run "${SCRIPT}"
  assert_success
  assert_output ""
}

@test "mode=max is the writer's business and does not count as drift" {
  _make_workflow ci "${REF}"
  _make_workflow publish "${REF}" "${REF},mode=max"
  _make_workflow warm-cache "${REF}" "${REF}"
  run "${SCRIPT}"
  assert_success
}

@test "a cache-from naming other sources beside the registry ref is not drift" {
  _write_workflow ci \
    "jobs:" \
    "  build:" \
    "    steps:" \
    "      - uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a" \
    "        with:" \
    "          cache-from: |" \
    "            ${REF}" \
    "            type=gha"
  _make_workflow publish "${REF}" "${REF},mode=max"
  _make_workflow warm-cache "${REF}" "${REF},mode=max"
  run "${SCRIPT}"
  assert_success
  assert_output ""
}

@test "a cache-from written as a YAML sequence is read like any other" {
  _write_workflow ci \
    "jobs:" \
    "  build:" \
    "    steps:" \
    "      - uses: docker/build-push-action@53b7df96c91f9c12dcc8a07bcb9ccacbed38856a" \
    "        with:" \
    "          cache-from:" \
    "            - ${REF}"
  _make_workflow publish "${REF}" "${REF},mode=max"
  _make_workflow warm-cache "${REF}" "${REF},mode=max"
  run "${SCRIPT}"
  assert_success
  assert_output ""
}

@test "exits 1 when a cache-from names no registry source at all" {
  _make_workflow ci "type=gha"
  _make_workflow publish "${REF}" "${REF},mode=max"
  _make_workflow warm-cache "${REF}" "${REF},mode=max"
  run "${SCRIPT}"
  assert_failure
  assert_output --partial "no 'cache-from' names a type=registry source"
}

@test "exits 1 when a workflow builds without a declared role" {
  # The hole a hardcoded file list would leave.
  _make_workflows
  _make_workflow rebuild "type=registry,ref=example:buildcache-other"
  run "${SCRIPT}"
  assert_failure
  assert_output --partial "rebuild.yml: has a docker/build-push-action step but no role"
}

@test "a workflow with no build step needs no role" {
  _make_workflows
  printf 'jobs:\n  x:\n    steps:\n      - run: echo hi\n' \
    > "${FAKE_REPO}/.github/workflows/renovate.yml"
  run "${SCRIPT}"
  assert_success
}

# ── drift ────────────────────────────────────────────────────────────

@test "exits 1 and names every spelling when the reader drifts from the writers" {
  local renamed='type=registry,ref=ghcr.io/knight-owl-dev/keystone-hook-diagrams:buildcache-${{ matrix.arch }}-v2'
  _make_workflow ci "${renamed}"
  _make_workflow publish "${REF}" "${REF},mode=max"
  _make_workflow warm-cache "${REF}" "${REF},mode=max"
  run "${SCRIPT}"
  assert_failure
  # Both spellings are reported, and neither is cast as the expectation.
  assert_output --partial 'buildcache-${{matrix.arch}}-v2'
  assert_output --partial 'named by: ci.yml cache-from'
  assert_output --partial 'named by: publish.yml cache-from, publish.yml cache-to, warm-cache.yml cache-from, warm-cache.yml cache-to'
}

@test "exits 1 when a writer exports a ref it does not read" {
  local other='type=registry,ref=ghcr.io/knight-owl-dev/keystone-hook-diagrams:buildcache-shared'
  _make_workflow ci "${REF}"
  _make_workflow publish "${REF}" "${REF},mode=max"
  _make_workflow warm-cache "${REF}" "${other},mode=max"
  run "${SCRIPT}"
  assert_failure
  assert_output --partial 'buildcache-shared'
  assert_output --partial 'named by: warm-cache.yml cache-to'
}

@test "exits 1 when env.IMAGE is undeclared, rather than comparing unresolved" {
  local via_env='type=registry,ref=${{ env.IMAGE }}:buildcache-${{ matrix.arch }}'
  _make_workflow ci "${REF}"
  _make_workflow publish "${via_env}" "${via_env},mode=max"
  _make_workflow warm-cache "${REF}" "${REF},mode=max"
  run "${SCRIPT}"
  assert_failure
  assert_output --partial 'env.IMAGE'
}

# ── missing pieces ───────────────────────────────────────────────────

@test "exits 1 when a build step declares no cache-from" {
  _make_workflow ci ""
  _make_workflow publish "${REF}" "${REF},mode=max"
  _make_workflow warm-cache "${REF}" "${REF},mode=max"
  run "${SCRIPT}"
  assert_failure
  assert_output --partial "no 'cache-from'"
}

@test "exits 1 when a writer stops exporting cache" {
  _make_workflow ci "${REF}"
  _make_workflow publish "${REF}" "${REF},mode=max"
  _make_workflow warm-cache "${REF}"
  run "${SCRIPT}"
  assert_failure
  assert_output --partial "no step exports 'cache-to'"
}

@test "exits 1 when the reader exports cache" {
  _make_workflow ci "${REF}" "${REF},mode=max"
  _make_workflow publish "${REF}" "${REF},mode=max"
  _make_workflow warm-cache "${REF}" "${REF},mode=max"
  run "${SCRIPT}"
  assert_failure
  assert_output --partial "only reads the cache"
}

@test "exits 1 when a workflow is absent" {
  _make_workflow ci "${REF}"
  _make_workflow publish "${REF}" "${REF},mode=max"
  run "${SCRIPT}"
  assert_failure
  assert_output --partial "warm-cache.yml: workflow not found"
}

@test "exits 1 when a workflow has no build step at all" {
  _make_workflows
  printf 'jobs:\n  build:\n    steps:\n      - run: echo hi\n' \
    > "${FAKE_REPO}/.github/workflows/warm-cache.yml"
  run "${SCRIPT}"
  assert_failure
  assert_output --partial "no docker/build-push-action step found"
}
