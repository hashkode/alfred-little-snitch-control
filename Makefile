.PHONY: all test lint build package-test icons clean

MEGALINTER_IMAGE ?= ghcr.io/oxsecurity/megalinter-cupcake:v10

# The MegaLinter image is amd64-only. Under emulation on Apple silicon, the
# shellcheck process that actionlint spawns for each `run:` block is killed
# intermittently, which surfaces as a spurious actionlint failure on whichever
# workflow file happens to be last. Turning off that one integration locally
# keeps `make lint` honest; CI runs natively and keeps it enabled.
ifeq ($(shell uname -m),arm64)
MEGALINTER_ENV ?= -e ACTION_ACTIONLINT_ARGUMENTS=-shellcheck=
else
MEGALINTER_ENV ?=
endif

# `test` is pure: no Little Snitch, no license, no password, no writes outside
# a temporary directory. `package-test` validates the built artifact.
all: test build package-test

test:
	./tests/run.zsh

# Runs the same linters as CI. Needs Docker. zsh is not covered — shellcheck
# and shfmt reject it — so `make test` carries the zsh syntax checks.
lint:
	docker run --rm -v "$(CURDIR)":/tmp/lint -e DEFAULT_WORKSPACE=/tmp/lint $(MEGALINTER_ENV) $(MEGALINTER_IMAGE)

build:
	./scripts/build.zsh

package-test: build
	./tests/package.zsh

icons:
	python3 scripts/make-icons.py workflow

clean:
	rm -rf dist
