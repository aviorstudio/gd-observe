#!/usr/bin/env bash
set -euo pipefail
mkdir -p .artifacts/bin
cargo build --locked --manifest-path cli/Cargo.toml
cp "${CARGO_TARGET_DIR:-cli/target}/debug/gdobs" .artifacts/bin/gdobs
bash scripts/build-addon-package.sh
bash scripts/verify-package.sh
