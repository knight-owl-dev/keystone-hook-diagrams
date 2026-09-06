#!/usr/bin/env bats
# shellcheck shell=bash
#
# Trivy substitutes built-in defaults for whatever trivy.yaml omits and reports
# no error, so a gutted policy scans clean.

load helpers/common

setup() {
  common_setup
}

@test "trivy.yaml declares the policy values it owns" {
  # `exit-code: 0` keeps the key and drops the gate, so the assertions compare
  # values.
  run yq -r '[
      .["exit-code"],
      (.severity | sort | join("+")),
      .vulnerability["ignore-unfixed"]
    ] | .[]' "${REPO_ROOT}/trivy.yaml"
  assert_success
  assert_line --index 0 '1'
  assert_line --index 1 'CRITICAL+HIGH'
  assert_line --index 2 'true'
}

@test "every suppression statement cites its tracking issue" {
  # A suppression is a promise to revisit, so it names where that promise is
  # tracked. Reading the parsed value makes this a truncation guard as well:
  # the file header owns the unquoted-scalar trap, and nothing else catches
  # it, since suppression keys on the id alone.
  #
  # An empty list passes: zero suppressions is the goal state.
  local stmt
  run yq -r '.vulnerabilities[].statement' "${REPO_ROOT}/.trivyignore.yaml"
  assert_success
  for stmt in "${lines[@]}"; do
    assert_regex "${stmt}" 'Tracking: (#[0-9]+, )*#[0-9]+\.'
    assert_regex "${stmt}" '\.$'
  done
}
