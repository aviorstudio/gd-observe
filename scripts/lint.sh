#!/usr/bin/env bash
set -euo pipefail
test -f addon/plugin.cfg
test -f addon/plugin.gd
test -f addon/autoload.gd
test -f addon/src/metrics_module.gd
test -f addon/src/metrics_live_server.gd
test -f addon/src/metrics_runtime_sampler.gd
test -f addon/src/observe_config.gd
test -f addon/src/observe_live_server_config.gd
test -f addon/src/observe_bootstrap.gd
test -f addon/presets/debug_observe_config.tres
test -f addon/presets/debug_live_server_config.tres
test -f addon/examples/app_shell/observe_example_main.tscn
test -f addon/examples/app_shell/observe_example_main.gd
test -f scripts/package/manifest.txt
test -f cli/Cargo.toml
cargo fmt --manifest-path cli/Cargo.toml --check
cargo clippy --locked --manifest-path cli/Cargo.toml --all-targets -- -D warnings
