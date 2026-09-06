#!/usr/bin/env bash
set -euo pipefail

#
# Prepare a release: stamp `version` with VERSION and open a "Release vVERSION"
# PR on a release/vVERSION branch. Merging that PR promotes tag vVERSION
# (.github/workflows/tag-release.yml), which triggers the publish workflow.
#
# Usage:
#   ./scripts/release.sh <major|minor|patch>   # bump latest release tag
#   ./scripts/release.sh <X.Y.Z>               # explicit version (escape hatch)
#
# Environment:
#   GH_TOKEN           (CI) GitHub App token used for push + PR creation, so the
#                      release PR triggers CI. Omit locally to use your own
#                      git/gh auth.
#   GITHUB_REPOSITORY  (CI) owner/repo, used to set the token push remote.
#
# Exit codes:
#   0 - Release PR opened
#   1 - Bad arguments, dirty tree, or nothing to release
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/lib/version.sh
source "${SCRIPT_DIR}/lib/version.sh"
# shellcheck source=scripts/lib/context.sh
source "${SCRIPT_DIR}/lib/context.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: $(basename "$0") <major|minor|patch|X.Y.Z>" >&2
  exit 1
fi

cd "${REPO_ROOT}"

# Best-effort refresh of tags before any tag-derived work: a bump verb reads
# them for the next-version base, and the diff below uses the stamped tag as the
# build-context baseline. Offline is tolerated (existing local tags are used).
git fetch --tags --quiet 2> /dev/null || true

# Resolve the target version. A bump verb derives the next version from the
# latest release tag — the same source publish.yml keys off, so there is no
# second source of truth to drift. An explicit X.Y.Z is the escape hatch for
# version jumps or corrections.
case "$1" in
  major | minor | patch)
    tags="$(git tag --list 'v*')"
    current="$(max_strict_version <<< "${tags}")"
    VERSION="$(bump_version "${current}" "$1")"
    echo "Latest release v${current} → bumping $1 → v${VERSION}"
    ;;
  *)
    # Strict semver, leading v stripped.
    VERSION="$(validate_strict_version "$1")"
    ;;
esac

# Require a clean tree: the stamp bump must be the only change in the release PR.
if ! git diff --quiet || ! git diff --staged --quiet; then
  echo "ERROR: working tree is not clean; commit or stash changes first" >&2
  exit 1
fi

# Refuse if a release PR is already open. Two concurrent release PRs stamp the
# same file against the same (last-tagged) baseline, so whichever merges first
# leaves the other wrong. Recovery is deliberate: the maintainer closes or
# merges the in-flight one before cutting another.
existing="$(
  gh pr list --state open --json number,headRefName \
    --jq 'map(select(.headRefName | startswith("release/v"))) | .[0].number // empty'
)"
if [[ -n "${existing}" ]]; then
  echo "ERROR: An open release PR already exists (#${existing}) — close or merge it before cutting another." >&2
  exit 1
fi

paths="$(image_source_paths "${REPO_ROOT}/.dockerignore")" || exit 1
mapfile -t context <<< "${paths}"

stamp=""
if [[ -f version ]]; then
  IFS= read -r stamp < version || true
fi

# An unknown baseline (never released, or the tag is missing) counts as changed.
if [[ -n "${stamp}" ]] && git rev-parse --verify --quiet "v${stamp}^{commit}" > /dev/null; then
  if git diff --quiet "v${stamp}...HEAD" -- "${context[@]}"; then
    echo "Nothing to release: the image build context is unchanged since v${stamp}." >&2
    exit 1
  fi
fi

echo "Releasing v${VERSION} (last released: v${stamp:-none})"

"${SCRIPT_DIR}/validate-version-strict.sh" "${VERSION}" > version

# In CI, set the bot identity and token remote BEFORE committing/pushing: the
# commit needs an author, and the push + PR must run as the App (whose token
# triggers PR CI). Locally, the caller's own git identity, remote, and gh auth
# are used.
if [[ -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  git config user.name "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"
  git remote set-url origin \
    "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
fi

# Open the release PR. The branch name encodes the version; tag-release.yml
# parses it and promotes the tag on merge.
BRANCH="release/v${VERSION}"
git switch -c "${BRANCH}"

git add version
git commit -m "Release v${VERSION}"

git push -u origin "${BRANCH}"

body="Merging this PR promotes tag v${VERSION}, which publishes the image."

pr_url="$(
  gh pr create --base main --head "${BRANCH}" \
    --title "Release v${VERSION}" \
    --body "${body}"
)"
echo "Opened ${pr_url}"

# Opt-in: `make release VERSION=X.Y.Z AUTOMERGE=1` merges once checks pass,
# making the whole release → tag → publish chain hands-off. Default is a
# deliberate manual merge after reviewing the stamp diff.
if [[ -n "${AUTOMERGE:-}" ]]; then
  echo "Enabling auto-merge (squash)..."
  gh pr merge --auto --squash "${pr_url}"
fi
