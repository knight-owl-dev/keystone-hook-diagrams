#!/usr/bin/env bash
# Shared helpers for the resolve script.

# Print an error message to stderr and exit with status 1.
#
# Arguments:
#   $@ - Error message text
die() {
  echo "ERROR: ${*}" >&2
  exit 1
}

# Fetch the latest version of an npm package from the registry.
#
# Arguments:
#   $1 - Package name (e.g. "mermaid")
#
# Outputs:
#   The latest version string (e.g. "11.17.2")
latest_npm_version() {
  local package="${1}"
  npm view "${package}" version 2> /dev/null \
    || die "failed to fetch latest npm version for ${package}"
}

# Rebuild package-lock.json from the package.json already in a directory.
#
# The stale lock is deleted rather than refreshed in place. `npm install
# --package-lock-only` keeps any pin still in range, so an incremental
# regenerate would freeze the tree at its first generation and stop absorbing
# transitive fixes.
#
# --package-lock-only resolves against the registry without installing, so
# this stays a metadata operation.
#
# Arguments:
#   $1 - Directory holding package.json
npm_relock() {
  local dir="${1}"

  rm -f "${dir}/package-lock.json"
  npm install --package-lock-only --silent --prefix "${dir}" > /dev/null 2>&1 \
    || die "failed to resolve the dependency tree in ${dir}"
  [[ -f "${dir}/package-lock.json" ]] \
    || die "no package-lock.json written in ${dir}"
}
