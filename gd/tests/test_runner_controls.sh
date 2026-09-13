#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner="$script_dir/run_tests.sh"
fixtures="$script_dir/runner_fixtures"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

expect_pass() {
  fixture="$1"
  rm -f "$scratch"/*
  cp "$fixtures/$fixture" "$scratch/$fixture"
  GODOT_TEST_TIMEOUT_SECONDS=2 "$runner" "$scratch"
}

expect_fail() {
  fixture="$1"
  rm -f "$scratch"/*
  cp "$fixtures/$fixture" "$scratch/$fixture"
  if GODOT_TEST_TIMEOUT_SECONDS=1 "$runner" "$scratch"; then
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
if GODOT_TEST_TIMEOUT_SECONDS=1 "$runner" "$scratch"; then
  echo "FAIL: gate accepted a missing Godot suite" >&2
  exit 1
fi
echo "PASS gate rejected missing suite"
expect_pass pass_test.gd
echo "PASS gd-observe runner controls restored"
