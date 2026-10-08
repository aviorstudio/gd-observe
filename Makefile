.DEFAULT_GOAL := help
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.NOTPARALLEL:
export PATH := $(CURDIR)/.artifacts/godot/bin:$(PATH)
export GODOT_BIN ?= godot
export PYTHONDONTWRITEBYTECODE := 1
.PHONY: help install lint test build artifact-smoke check dev stop clean
help:
	@echo 'make install check  Verify the Go CLI, Godot assertions and packaged editor lifecycle'
install:
	mise trust .mise.toml
	mise install go@1.27.1 python@3.13.11 http:cicd-engineering
	bash scripts/profile-install.sh
lint:
	bash scripts/profile-lint.sh
test:
	python3 tests/release_guard_test.py
	cd cli && go test -race -count=1 ./...
	bash gd/tests/test_runner_controls.sh
	bash gd/tests/test.sh
build:
	mkdir -p .artifacts/bin
	cd cli && go build -o ../.artifacts/bin/gdobs .
	bash scripts/build-addon-package.sh
	bash scripts/verify-package.sh
artifact-smoke:
	bash scripts/verify-editor-lifecycle.sh
check: lint test build artifact-smoke
dev stop:
	@echo '$@: unsupported: interactive addon use belongs to the consuming Godot project'
clean:
	python3 -c 'import shutil; [shutil.rmtree(path, ignore_errors=True) for path in (".artifacts", "dist")]'
