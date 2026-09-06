# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this is

One image: `ghcr.io/knight-owl-dev/keystone-hook-diagrams`, a Keystone hook that
renders mermaid fences. `src/server.js` is the whole renderer. See
[README.md](README.md) for the protocol and the shape of the image.

## Commands

Always use `make` targets; run `make help` for the list. Never invoke `shfmt`,
`shellcheck`, `hadolint`, `biome` or `cspell` directly — the Makefile runs them
from the pinned `ci-tools` image, and a host copy at another version disagrees.

`make test-image` needs `make build` first.

## Supply-chain security

The policy is org-wide:
[devops/docs/supply-chain-security.md](https://github.com/knight-owl-dev/devops/blob/main/docs/supply-chain-security.md).
Flag it explicitly if a change introduces a third-party Action wrapper, an
unverified binary source, or an unpinned dependency.

## Gotchas

- **Pin a base image by its manifest-list digest.** `docker buildx imagetools
  inspect` reports it as `application/vnd.oci.image.index.v1+json`. A digest
  from `docker pull` + `docker inspect` names one architecture and breaks the
  multi-platform build.
- **The two base digests move together.** The node binary is copied onto this
  Alpine and linked against its musl, so a lone bump risks an ABI mismatch that
  surfaces at container start.
- **A CVE in a transitively installed `apk` package needs a `>=` floor.** A
  rebuild alone keeps serving the vulnerable layer; the `RUN apk add` comment in
  the Dockerfile says why.
- **`.dockerignore` is an allowlist, and `scripts/lib/context.sh` reads it back
  to decide what a release watches.** A new path in the build has to be
  re-included there, or `make release` reports nothing to release over a real
  change.
- **Bump Trivy by hand, in all three places.** The Makefile and both workflows
  pin it in two different shapes; `make lint-actions` fails on drift, and
  Renovate is disabled for it.
- **ShellCheck runs with extra optional checks** (see `.shellcheckrc`). A piped
  or process-substituted command fails `check-extra-masked-returns` — capture
  into a variable first.
- **shfmt writes `2> /dev/null`**, with the space.
- **Biome formats `src/` and `tests/*.js` at width 80.** It has no array fill
  mode and discards author line breaks, so a compact list goes one per line and
  a short multi-line call collapses. Run `make lint-js-fix` and take the result.
- **An Action pin carries its full semver comment** (`# v7.0.1`) —
  `validate-action-pins` resolves the SHA against that exact tag.
- **Keep issue numbers out of commit messages.** `Refs #NN` and `Fixes #NN`
  belong in the PR description.
- **`main`'s ruleset names the CI jobs as required checks**, by string —
  including `Image (amd64)` and `Image (arm64)`, which `ci.yml` produces from a
  matrix. Renaming the job or changing an `arch` value leaves the required check
  waiting for a report that never comes, and every PR hangs rather than fails.
  Update the ruleset in the same change.

## Releasing

`make release BUMP=patch` stamps `version` and opens a `release/vX.Y.Z` PR;
merging promotes the tag, which publishes. `publish.yml` asserts the tag and the
`version` file agree.
