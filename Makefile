# Convenience targets around the scripts.  Every target forwards ARGS, e.g.
#
#   make verify ARGS="--verbose"
#
# The scripts remain the source of truth; the Makefile only exists so that
# `make`, `make verify` and `make doctor` are discoverable.

SHELL := /bin/bash
ARGS ?=

.PHONY: all build portable sign verify test doctor env clean distclean help

all: build

build:
	./build.sh $(ARGS)

portable:
	./build.sh --portable $(ARGS)

sign:
	./scripts/sign.sh $(ARGS)

verify test:
	./scripts/verify.sh $(ARGS)

doctor:
	./scripts/doctor.sh $(ARGS)

env:
	./scripts/env.sh $(ARGS)

clean:
	rm -rf build

distclean:
	rm -rf build dist .cache

help:
	@printf '%s\n' \
		'gdb-aarch64-darwin' \
		'' \
		'  make build       build, install and verify GDB' \
		'  make portable    self-contained build (static GMP/MPFR, no Python)' \
		'  make verify      run the smoke test against an existing install' \
		'  make sign        re-sign the installed GDB' \
		'  make doctor      check the toolchain, libraries and identity' \
		'  make env         print the PATH setup for the current shell' \
		'  make clean       remove the build directory' \
		'  make distclean   remove build, install and cached source trees' \
		'' \
		'  ARGS="..." passes options through, e.g. make build ARGS="--jobs 8"'
