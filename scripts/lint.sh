#!/usr/bin/env bash
set -euo pipefail
test -f gd/addon/plugin.cfg
test -f gd/addon/plugin.gd
test -f gd/addon/autoload.gd
test -f gd/addon/src/metrics_module.gd
test -f gd/addon/src/metrics_live_server.gd
test -f gd/addon/src/metrics_runtime_sampler.gd
test -f gd/addon/src/observe_config.gd
test -f gd/addon/src/observe_live_server_config.gd
test -f gd/addon/src/observe_bootstrap.gd
test -f gd/addon/presets/debug_observe_config.tres
test -f gd/addon/presets/debug_live_server_config.tres
test -f gd/addon/examples/app_shell/observe_example_main.tscn
test -f gd/addon/examples/app_shell/observe_example_main.gd
test -f gd/package-manifest.txt
test -f cli/Cargo.toml
cargo fmt --manifest-path cli/Cargo.toml --check
cargo clippy --locked --manifest-path cli/Cargo.toml --all-targets -- -D warnings
