#!/usr/bin/env bash
set -euo pipefail
python3 tests/release_guard_test.py
python3 tests/installer_test.py
cargo test --locked --manifest-path cli/Cargo.toml
bash gd/tests/test_runner_controls.sh
bash gd/tests/test.sh

python3 tests/tls_test.py
