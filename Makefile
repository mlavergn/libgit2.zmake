###############################################
#
# Makefile — ziglibgit2
#
# `make validate` is the pre-commit gate; `make build` is the entry point.
#
###############################################

# Optional include to extend the makefile targets
-include ../styleguide/Makefile.in

# The build description (build/) and host tools (zig/) are linted and
# formatted with the library and CLI.
ZIG_DIRS := src cli build zig

.DEFAULT_GOAL := all

.PHONY: build dist run cli clar

# ---------------------------------------------
# Configuration
# ---------------------------------------------

# The released version, read from build.zig.zon (the source of truth).
VERSION := $(shell sed -n -E 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' build.zig.zon)

# ---------------------------------------------
# Primary workflows
# ---------------------------------------------

# Build, format, and test.
all: build format test
	@echo "done"

# ---------------------------------------------
# Build
# ---------------------------------------------

# Build the library and CLI.
build:
	zig build

# Build optimized for release.
dist:
	zig build --release=fast

# Build the CLI (libgit2's git2), optimized, and run it. Pass arguments with
# `make cli ARGS="cat-file -p HEAD"`; with none, it prints its usage.
cli:
	zig build cli --release=fast
	./zig-out/bin/git2 $(ARGS)

# Build the CLI in debug and run it. Pass arguments with `make run ARGS="..."`.
run:
	zig build run -- $(ARGS)

# ---------------------------------------------
# Cross-compilation
# ---------------------------------------------

# Compile for Linux.
linux:
	zig build -Dtarget=x86_64-linux

# Compile for Windows.
windows:
	zig build -Dtarget=x86_64-windows

# List every target Zig can build for.
targets:
	zig targets

# ---------------------------------------------
# Test
# ---------------------------------------------

# Run the unit test suite.
test:
	zig build test --summary all

# Run libgit2's own clar suites against the Zig-built library.
clar:
	zig build clar

# ---------------------------------------------
# Documentation
# ---------------------------------------------

# Build the API docs and serve them locally.
docs:
	zig build docs
	open "http://127.0.0.1:8080" &
	python3 -m http.server -b 127.0.0.1 8080 -d zig-out/docs

# ---------------------------------------------
# Release
# ---------------------------------------------

# Tag the build.zig.zon version (e.g. 1.0.0) and push it.
tag:
	@test -n "$(VERSION)" || { echo "❌ could not read .version from build.zig.zon"; exit 1; }
	git tag -a "$(VERSION)" -m "$(VERSION)"
	git push
	git push --tags

# ---------------------------------------------
# Environment
# ---------------------------------------------

# Open the working copy in SourceTree.
st:
	open -a SourceTree .

# Open the project in the editor.
open:
	code .

# Open the repository on GitHub.
github:
	open "https://github.com/mlavergn/ziglibgit2"

# Clone a fresh working copy.
clone:
	git clone git@github.com:mlavergn/ziglibgit2.git

# Start Claude Code here.
claude:
	claude

# ---------------------------------------------
# Housekeeping
# ---------------------------------------------

# Remove every build artifact.
clean:
	rm -rf .zig-cache
	rm -rf zig-out
