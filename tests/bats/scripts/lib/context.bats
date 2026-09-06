#!/usr/bin/env bats
# shellcheck shell=bash
#
# Unit tests for scripts/lib/context.sh. The function decides what a release
# watches, so its failure mode is silent: a wrong list reports "nothing to
# release" over a real change, or releases on a docs edit.

load ../../helpers/common

setup() {
  common_setup
  LIB="${REPO_ROOT}/scripts/lib/context.sh"
  export LIB
}

# Writes a .dockerignore in the bats tmpdir and echoes its path.
_seed_dockerignore() {
  local file="${BATS_TEST_TMPDIR}/.dockerignore"
  printf '%s\n' "$@" > "${file}"
  echo "${file}"
}

# ── the allowlist ────────────────────────────────────────────────────

@test "echoes each re-included path, then the Dockerfile" {
  # shellcheck disable=SC1090
  source "${LIB}"
  local file
  file="$(_seed_dockerignore '*' '!package.json' '!src')"
  run image_source_paths "${file}"
  assert_success
  assert_line --index 0 'package.json'
  assert_line --index 1 'src'
  assert_line --index 2 'Dockerfile'
  assert_equal "${#lines[@]}" 3
}

@test "ignores exclusions, comments and blank lines" {
  # shellcheck disable=SC1090
  source "${LIB}"
  local file
  file="$(_seed_dockerignore '# a comment' '' '*' 'node_modules/' '!src')"
  run image_source_paths "${file}"
  assert_success
  assert_line --index 0 'src'
  assert_line --index 1 'Dockerfile'
  assert_equal "${#lines[@]}" 2
}

@test "strips only the leading bang" {
  # A path is re-included by a leading '!'; anything after it is the path.
  # shellcheck disable=SC1090
  source "${LIB}"
  local file
  file="$(_seed_dockerignore '*' '!weird!name.js')"
  run image_source_paths "${file}"
  assert_success
  assert_line --index 0 'weird!name.js'
}

@test "preserves .dockerignore order" {
  # shellcheck disable=SC1090
  source "${LIB}"
  local file
  file="$(_seed_dockerignore '*' '!zebra' '!alpha' '!middle')"
  run image_source_paths "${file}"
  assert_success
  assert_line --index 0 'zebra'
  assert_line --index 1 'alpha'
  assert_line --index 2 'middle'
}

# ── refusals ─────────────────────────────────────────────────────────

@test "fails when the allowlist is empty rather than watching the Dockerfile alone" {
  # The dangerous case: a denylist-shaped .dockerignore yields no paths, and a
  # gate that watched only the Dockerfile would call a src/ rewrite "no change".
  # shellcheck disable=SC1090
  source "${LIB}"
  local file
  file="$(_seed_dockerignore 'node_modules/' '.git/')"
  run image_source_paths "${file}"
  assert_failure 1
  assert_output --partial 'names no re-included path'
}

@test "fails when the file is missing" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run image_source_paths "${BATS_TEST_TMPDIR}/nosuch"
  assert_failure 1
  assert_output --partial 'unreadable'
}

@test "fails when called with no argument" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run image_source_paths
  assert_failure 1
  assert_output --partial 'requires a .dockerignore path'
}

# ── against the real file ────────────────────────────────────────────

@test "this repo's .dockerignore yields a usable watch list" {
  # The mechanism tests above run on fixtures, so nothing else would notice
  # .dockerignore being rewritten into a shape that yields nothing.
  # shellcheck disable=SC1090
  source "${LIB}"
  run image_source_paths "${REPO_ROOT}/.dockerignore"
  assert_success
  assert_line 'src'
  assert_line 'Dockerfile'
}
