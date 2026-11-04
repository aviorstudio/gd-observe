#!/usr/bin/env bash
set -euo pipefail
bash scripts/build-addon-package.sh
bash scripts/verify-package.sh
