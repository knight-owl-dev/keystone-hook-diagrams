#!/usr/bin/env bash
# What a release watches.

# Echo the repo-relative paths whose contents decide the published image, one
# per line, in .dockerignore order with the Dockerfile last.
#
# The allowlist is read back rather than restated here, because a second list
# drifts: a path added to the build but missed here turns the release gate into
# a no-op that reports "nothing to release" over a real change. The Dockerfile
# is named separately — it decides the image without being inside the context
# it describes.
#
# Arguments:
#   $1 - Path to the .dockerignore file
#
# Outputs:
#   One path per line
#
# Returns:
#   0 - At least one re-included path was found
#   1 - The file is unreadable, or names no re-included path
image_source_paths() {
  local dockerignore="${1:-}"

  if [[ -z "${dockerignore}" ]]; then
    echo "ERROR: image_source_paths requires a .dockerignore path" >&2
    return 1
  fi

  if [[ ! -r "${dockerignore}" ]]; then
    echo "ERROR: .dockerignore unreadable: ${dockerignore}" >&2
    return 1
  fi

  local allowlist
  allowlist="$(sed -n 's/^!//p' "${dockerignore}")"

  if [[ -z "${allowlist}" ]]; then
    echo "ERROR: ${dockerignore} names no re-included path — the release gate would watch only the Dockerfile" >&2
    return 1
  fi

  printf '%s\n' "${allowlist}"
  printf '%s\n' Dockerfile
}
