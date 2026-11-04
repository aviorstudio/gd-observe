#!/usr/bin/env bash
set -euo pipefail
python3 tests/release_guard_test.py
bash tests/godot/test_runner_controls.sh
bash tests/godot/test.sh
