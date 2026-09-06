#!/usr/bin/env bash
# shellcheck shell=bash
#
# Common bats helpers loaded by every suite under tests/bats/.
#
# Layout expectations:
#   REPO_ROOT is computed from BATS_TEST_DIRNAME by walking up to the first
#   ancestor containing a Makefile. Suite files should call `common_setup` from
#   their own setup().

# BATS_* variables are set by bats at runtime.
# shellcheck disable=SC2154

bats_load_library bats-support
bats_load_library bats-assert
bats_load_library bats-file

# Resolve the repo root by walking up from the test file.
_resolve_repo_root() {
  local dir="${BATS_TEST_DIRNAME}"
  while [[ "${dir}" != "/" && ! -f "${dir}/Makefile" ]]; do
    dir="$(dirname "${dir}")"
  done
  echo "${dir}"
}

# Set up a deterministic environment for a test.
#
# - REPO_ROOT   absolute path to the repo
common_setup() {
  REPO_ROOT="$(_resolve_repo_root)"
  export REPO_ROOT
}
