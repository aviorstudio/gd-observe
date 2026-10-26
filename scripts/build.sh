#!/usr/bin/env bash
set -euo pipefail
mkdir -p .artifacts/bin
(cd cli && go build -o ../.artifacts/bin/gdobs .)
bash scripts/build-addon-package.sh
bash scripts/verify-package.sh
