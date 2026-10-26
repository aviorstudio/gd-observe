#!/usr/bin/env bash
set -euo pipefail
python3 tests/release_guard_test.py
(cd cli && go test -race -count=1 ./...)
bash gd/tests/test_runner_controls.sh
bash gd/tests/test.sh
