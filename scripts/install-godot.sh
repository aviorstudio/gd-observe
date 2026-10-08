#!/usr/bin/env bash
set -euo pipefail
install_root="${1:-${RUNNER_TEMP:-/tmp}/gd-observe-godot}"
tools="$(python3 scripts/engineering-bootstrap.py)"
python3 "$tools/helpers/godot-setup.py" --version 4.7.2 \
  --binary-checksum sha256:cadd3204e728a35d3f13adb7fd0d7902636b79f6b95c40c265eb73b6c35329e4 \
  --root "$install_root" --origin godot
