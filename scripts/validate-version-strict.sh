#!/usr/bin/env bash
set -euo pipefail

#
# Validate that a version string is strict semver (MAJOR.MINOR.PATCH only).
#
# Rejects pre-release suffixes and malformed versions. Accepts an optional
# leading "v" prefix. Outputs the bare version (without "v") on success.
#
# Usage:
#   ./scripts/validate-version-strict.sh <version>
#
# Examples:
#   ./scripts/validate-version-strict.sh v1.0.0   # OK → "1.0.0"
#   ./scripts/validate-version-strict.sh 2.1.0    # OK → "2.1.0"
#   ./scripts/validate-version-strict.sh v1.0.0-rc1  # ERROR
#
# Exit codes:
#   0 - Valid strict semver
#   1 - Invalid version or missing argument
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/version.sh
source "${SCRIPT_DIR}/lib/version.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: $(basename "$0") <version>" >&2
  exit 1
fi

validate_strict_version "$1"
