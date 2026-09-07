#!/usr/bin/env bash
set -euo pipefail

# validate-cache-refs.sh — Validate that the build cache ref is spelled
# identically everywhere it is written and read.
#
# warm-cache.yml and publish.yml write buildcache-<arch>; ci.yml reads it. That
# is one string across three files, and buildx fails open on it: an
# unresolvable ref is a cache miss, so a rename on one side leaves slower
# builds and green checks with no error.
#
# Usage:
#   scripts/lib/validate-cache-refs.sh
#
# Exit codes:
#   0 - Every build step reads one identical ref, and only the writers write it
#   1 - A ref drifted or is missing, or a workflow's role is wrong or undeclared

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORKFLOWS="${REPO_ROOT}/.github/workflows"

# A reader restores cache and must never export it: ci.yml runs on pull
# requests, and one from a fork gets no packages: write.
#
# Roles are declared rather than inferred: reading a writer off the presence of
# cache-to would classify a writer that forgot its export as a reader. Any
# other workflow that grows a build step fails below until it is named here.
readers=(ci.yml)
writers=(publish.yml warm-cache.yml)

errors=0
fail() {
  echo "$1" >&2
  errors=1
}

# Every ref seen, and what named it, so a mismatch can say where.
refs=()
sources=()

# The steps that take a cache ref.
step_query='.jobs[]?.steps[]?
  | select(.uses // "" | test("^docker/build-push-action@"))'

# record <label> <image> <lines>
#
# File each type=registry ref in <lines> under <label>. A cache input takes
# several sources — `type=gha` beside the shared ref is legitimate — and only
# registry refs are this gate's business. <image> is the workflow's own
# env.IMAGE, so a file that spells the registry inline and one that goes
# through the variable still compare equal.
record() {
  local label="$1" image="$2" lines="$3"
  local line canon

  while IFS= read -r line; do
    # A YAML sequence arrives as "- <value>"; a block scalar as bare lines.
    line="${line#- }"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ "${line}" == type=registry* ]] || continue

    # Actions ignores the spacing inside an expression; string equality does not.
    canon="$(sed -E 's/\$\{\{[[:space:]]*/${{/g; s/[[:space:]]*\}\}/}}/g' <<< "${line}")"

    # The single quotes are the point: this is an Actions expression to match
    # literally, not one for the shell to expand — hence the SC2016 directive.
    # shellcheck disable=SC2016
    if [[ "${canon}" == *'${{env.IMAGE}}'* ]]; then
      if [[ -z "${image}" ]]; then
        fail "${label}: names \${{ env.IMAGE }}, but the workflow declares no top-level env.IMAGE"
        continue
      fi
      canon="${canon//\$\{\{env.IMAGE\}\}/${image}}"
    fi

    # The ref ends before mode=max, which is the writer's business.
    refs+=("${canon//,mode=max/}")
    sources+=("${label}")
  done <<< "${lines}"
}

# build_step_count <workflow path>
build_step_count() {
  yq -r "[${step_query}] | length" "$1"
}

# collect <workflow> reader|writer
collect() {
  local name="$1" role="$2"
  local path="${WORKFLOWS}/${name}"

  if [[ ! -f "${path}" ]]; then
    fail "${name}: workflow not found"
    return
  fi

  local steps with_from
  steps="$(build_step_count "${path}")"
  if [[ "${steps}" -eq 0 ]]; then
    fail "${name}: no docker/build-push-action step found"
    return
  fi

  # Counted rather than read per step: a multi-source input arrives as several
  # lines, so the ref stream below cannot say which step produced what.
  with_from="$(yq -r "[${step_query} | select(.with[\"cache-from\"] != null)] | length" "${path}")"
  if [[ "${with_from}" -ne "${steps}" ]]; then
    fail "${name}: a build step declares no 'cache-from' — it would build every layer from scratch"
  fi

  local image from_refs to_refs before
  image="$(yq -r '.env.IMAGE // ""' "${path}")"
  # `select(. != null)` rather than jq's `empty`: yq here is the Go
  # implementation, which has no such filter.
  from_refs="$(yq -r "${step_query} | .with[\"cache-from\"] | select(. != null)" "${path}")"
  to_refs="$(yq -r "${step_query} | .with[\"cache-to\"] | select(. != null)" "${path}")"

  before="${#refs[@]}"
  record "${name} cache-from" "${image}" "${from_refs}"
  if [[ "${#refs[@]}" -eq "${before}" ]]; then
    fail "${name}: no 'cache-from' names a type=registry source — it reads none of the shared cache"
  fi

  if [[ -z "${to_refs}" ]]; then
    if [[ "${role}" == "writer" ]]; then
      fail "${name}: no step exports 'cache-to' — the cache it is meant to write would stay cold"
    fi
    return
  fi

  if [[ "${role}" == "reader" ]]; then
    fail "${name}: exports 'cache-to', but it only reads the cache"
    return
  fi

  record "${name} cache-to" "${image}" "${to_refs}"
}

for path in "${WORKFLOWS}"/*.yml; do
  [[ -f "${path}" ]] || continue
  name="${path##*/}"
  declared=0
  for known in "${readers[@]}" "${writers[@]}"; do
    if [[ "${known}" == "${name}" ]]; then
      declared=1
      break
    fi
  done
  [[ "${declared}" -eq 0 ]] || continue
  steps="$(build_step_count "${path}")"
  if [[ "${steps}" -gt 0 ]]; then
    fail "${name}: has a docker/build-push-action step but no role — add it to readers or writers in validate-cache-refs.sh"
  fi
done

for workflow in "${readers[@]}"; do
  collect "${workflow}" reader
done
for workflow in "${writers[@]}"; do
  collect "${workflow}" writer
done

# Which spelling is right is not knowable here: the reader is as likely to have
# drifted as the writers. So a mismatch lists every distinct ref with what
# names it, rather than electing one.
declare -A named_by=()
for i in "${!refs[@]}"; do
  ref="${refs[i]}"
  if [[ -n "${named_by[${ref}]:-}" ]]; then
    named_by["${ref}"]+=", ${sources[i]}"
  else
    named_by["${ref}"]="${sources[i]}"
  fi
done

if [[ "${#named_by[@]}" -gt 1 ]]; then
  {
    echo "the build cache ref is not spelled identically everywhere:"
    for ref in "${!named_by[@]}"; do
      echo "  ${ref}"
      echo "    named by: ${named_by[${ref}]}"
    done
  } >&2
  errors=1
fi

[[ "${errors}" -eq 0 ]] || exit 1
