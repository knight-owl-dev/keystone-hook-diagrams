.DEFAULT_GOAL := help

IMAGE_TAG ?= keystone-hook-diagrams:local

# The lint toolchain, pinned by manifest-list digest. The v-tag rides along for
# readability; the digest is what resolves, so bump both together.
CI_TOOLS_IMAGE ?= ghcr.io/knight-owl-dev/ci-tools:v1.4.6@sha256:26d036507053db51a2c94ac2a45d1c048e2a1227bb600c8cc80ba6c4358e614f

# Whether a human is watching. Probed once; the container TTY keys off it.
IS_TTY := $(shell test -t 0 && echo 1)

# Pass `-t` to `docker run` when stdin is a terminal, so TTY-aware tools see a
# real terminal inside the container.
# Override with `DOCKER_TTY=` (empty) or `DOCKER_TTY=-t` (force) as needed.
DOCKER_TTY ?= $(if $(IS_TTY),-t)

.PHONY: sync resolve build scan clean set-version get-version release \
	lint lint-fix lint-docker lint-sh lint-sh-fmt lint-sh-fmt-fix lint-js lint-js-fix \
	lint-actions lint-md lint-md-fix lint-spell test test-bats test-image samples help

# Resolve latest versions, build, and test the image
sync: resolve build test-image

# Resolve the npm dependency tree (TOOLS=mermaid:11.12.0 pins one)
resolve:
	@scripts/resolve.sh $(TOOLS)

# Set the release version. Validated into a variable first: redirecting straight
# into the file would truncate it before a bad version was rejected.
set-version:
	@v="$$(scripts/validate-version-strict.sh '$(VERSION)')" \
		&& printf '%s\n' "$$v" > version \
		&& echo "Set version to $$v"

# Print the release version
get-version:
	@scripts/validate-version-strict.sh "$$(cat version)"

# Open a release PR: stamp `version` and open "Release vVERSION" (merging it
# promotes the tag). The version is either bumped from the latest release tag
# (BUMP=patch|minor|major) or set explicitly (VERSION=X.Y.Z, which wins if both
# are given). Pass AUTOMERGE=1 to enable auto-merge once checks pass.
release:
	@AUTOMERGE='$(AUTOMERGE)' scripts/release.sh $(if $(VERSION),$(VERSION),$(BUMP))

# Build the image locally. IMAGE_VERSION stays at its Dockerfile default, so a
# local build reports no cache identity — publish.yml passes the release tag.
build:
	@docker compose build

# Render the theme and look samples the README embeds. Regenerate when mermaid
# or Chromium moves what a theme draws; nothing gates this, so it is by hand.
samples:
	@IMAGE_TAG="$(IMAGE_TAG)" ./scripts/generate-samples.sh

# Integration-test the built image. Runs host-side, because the container has
# no shell and its ENTRYPOINT owns argv — tests/test-image.sh says why.
test-image:
	@IMAGE_TAG="$(IMAGE_TAG)" ./tests/test-image.sh

# Scan the image for vulnerabilities. Policy lives in trivy.yaml; only the
# suppression file is passed here. NO_IGNORE=1 reports what .trivyignore.yaml
# hides, overriding trivy.yaml's exit code so the report doesn't fail the build.
ifdef NO_IGNORE
TRIVY_FLAGS := --ignorefile /dev/null --exit-code 0
else
TRIVY_FLAGS := --ignorefile .trivyignore.yaml
endif

# Keep in sync with the trivy-action `version:` in publish.yml and
# cve-monitor.yml (see trivy.yaml).
TRIVY_IMAGE := aquasec/trivy:0.74.0

scan: build
	@echo "Scanning $(IMAGE_TAG) for vulnerabilities$(if $(NO_IGNORE), (suppressions disabled),)..."
	@docker run --rm $(DOCKER_TTY) \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v "$(CURDIR):/repo:ro" \
		-w /repo \
		$(TRIVY_IMAGE) image \
		--config trivy.yaml \
		$(TRIVY_FLAGS) \
		$(IMAGE_TAG)

# Run all linters. SKIP='lint-a lint-b' drops targets from the run — bootstraps
# a linter whose tool is not yet in the pinned ci-tools image.
LINT_TARGETS := lint-docker lint-sh lint-sh-fmt lint-js lint-actions lint-md lint-spell

# The lint targets invoke their tools bare, so the toolchain comes from wherever
# make runs, and host tools drift from the image's — shfmt formats differently
# across minor versions. The aggregate targets therefore re-enter the image,
# in CI as well as locally: this is the only place naming CI_TOOLS_IMAGE, so
# there is no second pin for a workflow to drift from.
#
# GITHUB_TOKEN is forwarded because validate-action-pins resolves each pinned
# SHA against the API, and 60 anonymous requests an hour does not cover a
# workflow set. Unset locally, it passes nothing.
LINT_RUNNER ?= docker run --rm $(DOCKER_TTY) -e GITHUB_TOKEN \
	-v "$(CURDIR):/work" -w /work $(CI_TOOLS_IMAGE) make

lint:
	@$(LINT_RUNNER) $(filter-out $(SKIP),$(LINT_TARGETS))

# Fix all auto-fixable lint issues. Containerized alongside lint: a host shfmt
# that formats differently would write what the image then rejects.
lint-fix:
	@$(LINT_RUNNER) lint-sh-fmt-fix lint-js-fix lint-md-fix

# Lint the Dockerfile
lint-docker:
	@echo "Linting Dockerfile..." && hadolint Dockerfile && echo "OK"

# Lint shell scripts.
#
# Discovery is `find`, so a script at a new depth gets linted without anyone
# widening a glob — the bats suites were missed exactly that way.
#
# Both lists are asserted non-empty because shellcheck given no files exits 0
# having read nothing, so broken discovery would pass this gate green.
#
# SC2154 is suppressed for bats only. Those files reference variables bats sets
# at runtime (output, BATS_TEST_DIRNAME, ...) plus helper-exported ones
# shellcheck cannot trace across bats_load_library.
lint-sh:
	@echo "Linting shell scripts..."
	@set -eu; \
		scripts="$$(find scripts tests -type f -name '*.sh')"; \
		bats="$$(find tests/bats -type f \( -name '*.bats' -o -name '*.bash' \))"; \
		[ -n "$${scripts}" ] || { echo "ERROR: found no *.sh — discovery is broken" >&2; exit 1; }; \
		[ -n "$${bats}" ] || { echo "ERROR: found no bats files — discovery is broken" >&2; exit 1; }; \
		shellcheck $${scripts}; \
		shellcheck -e SC2154 $${bats}
	@echo "OK"

# Check shell script formatting
lint-sh-fmt:
	@echo "Checking shell script formatting..." \
		&& shfmt -d -i 2 -ci -bn -sr scripts/ tests/ \
		&& echo "OK"

# Fix shell script formatting
lint-sh-fmt-fix:
	@echo "Fixing shell script formatting..." \
		&& shfmt -w -i 2 -ci -bn -sr scripts/ tests/ \
		&& echo "OK"

# Lint and format-check JavaScript.
#
# --error-on-warnings because Biome reports most rules as warnings and would
# otherwise exit 0 on every finding, gating nothing.
lint-js:
	@echo "Checking JavaScript..." && biome check --error-on-warnings && echo "OK"

# Fix JavaScript formatting and auto-fixable lint issues
lint-js-fix:
	@echo "Fixing JavaScript..." && biome check --write && echo "OK"

# Lint GitHub Actions workflows
lint-actions:
	@echo "Linting GitHub Actions..." \
		&& actionlint .github/workflows/*.yml \
		&& echo "OK"
	@echo "Validating GitHub Actions pins..." \
		&& validate-action-pins .github/workflows/*.yml \
		&& echo "OK"
	@echo "Validating Trivy version pins..." \
		&& scripts/lib/validate-trivy-pins.sh \
		&& echo "OK"
	@echo "Validating build cache refs..." \
		&& scripts/lib/validate-cache-refs.sh \
		&& echo "OK"

# Lint Markdown files
lint-md:
	@echo "Linting Markdown..." && markdownlint-cli2 '**/*.md' && echo "OK"

# Fix Markdown files
lint-md-fix:
	@echo "Fixing Markdown..." && markdownlint-cli2 --fix '**/*.md' && echo "OK"

# Check spelling. --gitignore reuses .gitignore, so ignore paths live in one place.
lint-spell:
	@echo "Checking spelling..." && cspell --no-progress --gitignore '**/*' && echo "OK"

# Run BATS tests. BATS_RUNNER defaults to running inside the ci-tools container,
# so `make test-bats` works from a stock macOS host without bats installed. CI
# (already inside the container) overrides with `BATS_RUNNER=bats`.
BATS_RUNNER ?= docker run --rm $(DOCKER_TTY) \
	-v "$(CURDIR):/work" -w /work $(CI_TOOLS_IMAGE) bats

# bats defaults to TAP whatever it is attached to — its own --help claims
# otherwise, and the terminal check it does run only decorates a formatter
# already set to pretty. Ask for pretty when someone is watching, and leave CI
# on TAP.
BATS_FORMAT := $(if $(IS_TTY),--pretty)

test-bats:
	@$(BATS_RUNNER) $(BATS_FORMAT) -r tests/bats/

# Everything testable. test-image needs a built image; test-bats does not.
test: test-bats test-image

# Remove the local image
clean:
	@echo "Removing $(IMAGE_TAG) ..."
	@docker rmi $(IMAGE_TAG) 2> /dev/null || true
	@echo "OK"

# Show all commands
help:
	@echo ""
	@echo "keystone-hook-diagrams Commands:"
	@echo "  make sync              Resolve, build, and test the image"
	@echo "  make resolve           Resolve npm dependencies to latest"
	@echo "  make resolve TOOLS=... Pin specific packages (e.g. mermaid:11.12.0)"
	@echo "  make set-version VERSION=1.3.0  Set the release version"
	@echo "  make get-version       Print the release version"
	@echo "  make release BUMP=patch    Open a release PR, version bumped from latest tag"
	@echo "  make release VERSION=1.3.0 Open a release PR at an explicit version"
	@echo "  make build             Build the image locally"
	@echo "  make scan              Scan the image for vulnerabilities"
	@echo "  make scan NO_IGNORE=1  Scan without .trivyignore.yaml suppressions"
	@echo "  make clean             Remove the local image"
	@echo "  make lint              Run all linters"
	@echo "  make lint SKIP=...     Run all linters except the named targets"
	@echo "  make lint-actions      Lint GitHub Actions workflows"
	@echo "  make lint-docker       Lint the Dockerfile"
	@echo "  make lint-fix          Fix all auto-fixable lint issues"
	@echo "  make lint-md           Lint Markdown files"
	@echo "  make lint-js           Lint and format-check JavaScript (biome)"
	@echo "  make lint-js-fix       Fix JavaScript formatting and lint issues"
	@echo "  make lint-md-fix       Fix Markdown files"
	@echo "  make lint-spell        Check spelling"
	@echo "  make lint-sh           Lint shell scripts"
	@echo "  make lint-sh-fmt       Check shell script formatting"
	@echo "  make lint-sh-fmt-fix   Fix shell script formatting"
	@echo "  make test              Run all tests (bats + image)"
	@echo "  make test-bats         Run BATS tests inside the ci-tools image"
	@echo "  make test-image        Integration-test the built image"
	@echo "  make samples           Re-render the theme samples in docs/samples"
	@echo "  make help              Show this message"
	@echo ""
