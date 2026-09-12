#!/usr/bin/env bash
set -euo pipefail

script_dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot="${GODOT_BIN:-godot}"
timeout_seconds="${GODOT_TEST_TIMEOUT_SECONDS:-30}"
log_dir="$(mktemp -d)"
isolated_home="$(mktemp -d)"
trap 'rm -rf "$log_dir" "$isolated_home"' EXIT

shopt -s nullglob
tests=("$script_dir"/*_test.gd)
if [ "${#tests[@]}" -eq 0 ]; then
  echo "FAIL: no Godot test scripts found in $script_dir" >&2
  exit 1
fi

failures=0
reached=0
for test in "${tests[@]}"; do
  name="$(basename "$test" .gd)"
  log="$log_dir/$name.log"
  echo "Running $name.gd..."
  set +e
  HOME="$isolated_home" timeout --signal=TERM --kill-after=5 "${timeout_seconds}s" \
    "$godot" --headless --path "$root_dir" --script "$test" 2>&1 | tee "$log"
  status="${PIPESTATUS[0]}"
  set -e
  sentinel_count="$(grep -cFx "PASS gd-observe $name" "$log" || true)"
  if [ "$sentinel_count" -eq 1 ]; then
    reached=$((reached + 1))
  fi
  if [ "$status" -ne 0 ] || grep -Eq '^(ERROR:|SCRIPT ERROR:|FAIL:)' "$log" || [ "$sentinel_count" -ne 1 ]; then
    echo "FAIL: $name (exit=$status, sentinel_count=$sentinel_count)" >&2
    failures=$((failures + 1))
  fi
done

echo "Godot assertions reached: $reached/${#tests[@]}"
if [ "$failures" -ne 0 ] || [ "$reached" -ne "${#tests[@]}" ]; then
  exit 1
fi
