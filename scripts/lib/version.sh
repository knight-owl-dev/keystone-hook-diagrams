#!/usr/bin/env bash
# Shared version helpers.

# Validate that a version string is strict semver (MAJOR.MINOR.PATCH only).
#
# Rejects pre-release suffixes (e.g. 1.0.0-rc1) and malformed versions.
# Accepts an optional leading "v" prefix which is stripped before validation.
#
# Arguments:
#   $1 - Version string to validate (e.g. "v1.2.3" or "1.2.3")
#
# Outputs:
#   The bare version string (without "v" prefix) on success
#
# Returns:
#   0 - Valid strict semver
#   1 - Invalid or missing argument
validate_strict_version() {
  if [[ $# -ne 1 ]] || [[ -z "$1" ]]; then
    echo "ERROR: Version argument required" >&2
    return 1
  fi

  local version="${1#v}"

  if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid strict version: $1" >&2
    echo "Expected: MAJOR.MINOR.PATCH (e.g., v1.0.0) with no pre-release suffix" >&2
    return 1
  fi

  echo "${version}"
}

# Echo the highest strict-semver version from newline-separated stdin.
#
# Keeps only bare or "v"-prefixed MAJOR.MINOR.PATCH lines, discarding
# everything else (pre-releases like v1.0.0-rc1, branch-style refs), and
# echoes the greatest by semver order with any "v" stripped. Echoes
# "0.0.0" when no strict-semver line is present, so a fresh repo with no
# release tags yields a sane bump base.
#
# Reads candidates from stdin (e.g. `git tag --list 'v*' | max_strict_version`)
# so the git I/O lives in the caller, keeping this pure and testable.
#
# Outputs:
#   The highest bare version string, or "0.0.0"
#
# Returns:
#   0 - Always
max_strict_version() {
  local candidates sorted highest
  candidates="$(grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$')" || candidates=""

  if [[ -z "${candidates}" ]]; then
    echo "0.0.0"
    return 0
  fi

  sorted="$(sort -V <<< "${candidates}")"
  highest="$(tail -n1 <<< "${sorted}")"
  echo "${highest#v}"
}

# Compute the next strict-semver version by bumping one component.
#
# Bumping a component resets all lower ones to zero: a major bump zeroes
# minor and patch; a minor bump zeroes patch.
#
# Arguments:
#   $1 - Current version (strict semver, optional leading "v")
#   $2 - Component to bump: major | minor | patch
#
# Outputs:
#   The bumped bare version string on success
#
# Returns:
#   0 - Success
#   1 - Invalid current version or unknown component
bump_version() {
  local current component major minor patch
  current="$(validate_strict_version "${1:-}")" || return 1
  component="${2:-}"

  IFS=. read -r major minor patch <<< "${current}"

  case "${component}" in
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    patch)
      patch=$((patch + 1))
      ;;
    *)
      echo "ERROR: Unknown bump component: ${component:-(none)}" >&2
      echo "Expected: major | minor | patch" >&2
      return 1
      ;;
  esac

  echo "${major}.${minor}.${patch}"
}
