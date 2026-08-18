.PHONY: all test build package-test icons clean

# `test` is pure: no Little Snitch, no license, no password, no writes outside
# a temporary directory. `package-test` validates the built artifact.
all: test build package-test

test:
	./tests/run.zsh

build:
	./scripts/build.zsh

package-test: build
	./tests/package.zsh

icons:
	python3 scripts/make-icons.py workflow

clean:
	rm -rf dist
