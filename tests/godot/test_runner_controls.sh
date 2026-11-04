#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner="${TOOLS_ROOT:?Pinned cookbook tools required}/helpers/godot-test.py"
project="$(cd "$script_dir/../.." && pwd)"
fixtures="$script_dir/runner_fixtures"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

expect_pass() {
  fixture="$1"
  rm -f "$scratch"/*
  cp "$fixtures/$fixture" "$scratch/$fixture"
  python3 "$runner" --project "$project" --directory "$scratch" --sentinel-prefix "PASS gd-observe" --timeout 2
}

expect_fail() {
  fixture="$1"
  rm -f "$scratch"/*
  cp "$fixtures/$fixture" "$scratch/$fixture"
  if python3 "$runner" --project "$project" --directory "$scratch" --sentinel-prefix "PASS gd-observe" --timeout 1; then
    echo "FAIL: gate accepted negative control $fixture" >&2
    exit 1
  fi
  echo "PASS gate rejected $fixture"
}

expect_fail runtime_error_zero_exit_test.gd
expect_fail assertion_overwritten_test.gd
expect_fail unreachable_assertion_test.gd
expect_fail parse_failure_test.gd
expect_fail timeout_test.gd
rm -f "$scratch"/*
if python3 "$runner" --project "$project" --directory "$scratch" --sentinel-prefix "PASS gd-observe" --timeout 1; then
  echo "FAIL: gate accepted a missing Godot suite" >&2
  exit 1
fi
echo "PASS gate rejected missing suite"
expect_pass pass_test.gd
echo "PASS gd-observe runner controls restored"
