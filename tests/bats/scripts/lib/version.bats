#!/usr/bin/env bats
# shellcheck shell=bash
#
# Unit tests for scripts/lib/version.sh. Each test sources the
# library and invokes a single function so side effects stay
# isolated to the bats subshell.

load ../../helpers/common

setup() {
  common_setup
  LIB="${REPO_ROOT}/scripts/lib/version.sh"
  export LIB
}

# ── validate_strict_version ───────────────────────────────────────

@test "validate_strict_version accepts MAJOR.MINOR.PATCH and echoes the bare version" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run validate_strict_version "1.2.3"
  assert_success
  assert_output "1.2.3"
}

@test "validate_strict_version strips a leading v prefix" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run validate_strict_version "v1.2.3"
  assert_success
  assert_output "1.2.3"
}

@test "validate_strict_version rejects a pre-release suffix" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run validate_strict_version "1.0.0-rc1"
  assert_failure 1
  assert_output --partial "Invalid strict version"
}

@test "validate_strict_version rejects a two-segment version" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run validate_strict_version "1.2"
  assert_failure 1
  assert_output --partial "Invalid strict version"
}

@test "validate_strict_version rejects an empty argument" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run validate_strict_version ""
  assert_failure 1
  assert_output --partial "Version argument required"
}

@test "validate_strict_version rejects a missing argument" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run validate_strict_version
  assert_failure 1
  assert_output --partial "Version argument required"
}

# ── max_strict_version ────────────────────────────────────────────

@test "max_strict_version echoes the highest of several tags, v-stripped" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run max_strict_version <<< $'v1.2.7\nv1.3.0\nv1.2.10'
  assert_success
  assert_output "1.3.0"
}

@test "max_strict_version orders by semver, not lexically" {
  # 1.2.10 > 1.2.9 numerically, but sorts lower as a string.
  # shellcheck disable=SC1090
  source "${LIB}"
  run max_strict_version <<< $'v1.2.9\nv1.2.10'
  assert_success
  assert_output "1.2.10"
}

@test "max_strict_version ignores pre-releases and non-version lines" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run max_strict_version <<< $'v1.3.0\nv2.0.0-rc1\nrelease/v1.9.0\nlatest'
  assert_success
  assert_output "1.3.0"
}

@test "max_strict_version accepts bare versions without a v prefix" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run max_strict_version <<< $'1.2.7\n1.4.1'
  assert_success
  assert_output "1.4.1"
}

@test "max_strict_version echoes 0.0.0 when no strict version is present" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run max_strict_version <<< $'latest\nmain\nv2.0.0-beta'
  assert_success
  assert_output "0.0.0"
}

@test "max_strict_version echoes 0.0.0 for empty input" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run max_strict_version < /dev/null
  assert_success
  assert_output "0.0.0"
}

# ── bump_version ─────────────────────────────────────────────────────

@test "bump_version patch increments the patch component" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run bump_version "1.2.7" patch
  assert_success
  assert_output "1.2.8"
}

@test "bump_version minor increments minor and resets patch to zero" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run bump_version "1.2.7" minor
  assert_success
  assert_output "1.3.0"
}

@test "bump_version major increments major and resets minor and patch to zero" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run bump_version "1.2.7" major
  assert_success
  assert_output "2.0.0"
}

@test "bump_version strips a leading v prefix from the current version" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run bump_version "v1.2.7" patch
  assert_success
  assert_output "1.2.8"
}

@test "bump_version rejects an unknown component" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run bump_version "1.2.7" build
  assert_failure 1
  assert_output --partial "Unknown bump component"
}

@test "bump_version rejects a missing component" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run bump_version "1.2.7"
  assert_failure 1
  assert_output --partial "Unknown bump component"
}

@test "bump_version rejects a malformed current version" {
  # shellcheck disable=SC1090
  source "${LIB}"
  run bump_version "1.2" patch
  assert_failure 1
  assert_output --partial "Invalid strict version"
}
