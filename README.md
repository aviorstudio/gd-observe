# gd-observe

Local observability tooling for Godot 4.

Use this addon to collect gameplay timings, gauges, counters, Godot runtime stats, and inspect them through a live terminal dashboard before deciding whether any data should be sent to an external service.

## Installation

### Via gdam

`gdam install @aviorstudio/gd-observe`

### Manual

Copy `gd/addon/` into `res://addons/@aviorstudio_gd-observe/` and enable the plugin.

The plugin registers a `GdObserve` autoload when enabled.

## Quick Start

For editor-first projects, add an `ObserveBootstrap` node to your app shell scene and assign resource configs:

```text
Main
  ObserveBootstrap
    metrics_config = res://addons/@aviorstudio_gd-observe/presets/debug_observe_config.tres
    live_server_config = res://addons/@aviorstudio_gd-observe/presets/debug_live_server_config.tres
    live_server_mode = DEBUG_NON_WEB
    context_tags = { "game": "my_game" }
```

`ObserveBootstrap` configures the `GdObserve` autoload on scene ready, applies shared context tags, can start the live server in debug builds, and reads optional `gdobs_host` / `gdobs_port` overrides from `res://.env.json`.

An installable example scene is included at:

```text
res://addons/@aviorstudio_gd-observe/examples/app_shell/observe_example_main.tscn
```

Script-only setup still works:

```gdscript
func _ready() -> void:
	GdObserve.configure(MetricsModule.MetricsConfig.new(true, 500))

func _run_expensive_step() -> void:
	var timer: int = GdObserve.begin_timer()
	_expensive_work()
	GdObserve.finish_timer("CombatService.resolve", timer, {"phase": "combat"})
```

Shared context can be attached once and automatically applied to timers, gauges, counters, logs, and events:

```gdscript
GdObserve.push_context({"route": "match", "match_type": "pve"})
GdObserve.increment_counter("BoardInput.hex_clicked")
GdObserve.pop_context()
```

For multi-step flows, use spans and runtime checkpoints:

```gdscript
var span := GdObserve.begin_span("Match.startup")
_build_board()
span.checkpoint("board_ready")
_build_hands()
span.finish({"result": "ok"})

GdObserve.checkpoint_runtime("after_match_ready")
```

## Metric Kinds

- `timer`: retained duration samples in microseconds, summarized with count, avg, p50, p95, p99, max, and latest.
- `gauge`: latest numeric value, useful for current pool sizes, queue depth, node counts, etc.
- `counter`: monotonically accumulated values, useful for events like object pool creates/acquires/returns.

```gdscript
GdObserve.finish_timer("BoardVisualService.hex_screen_resolve", timer, {"service": "BoardVisualService"})
GdObserve.set_gauge("ObjectPool.unit.available", 42, "count", {"pool": "unit"})
GdObserve.increment_counter("ObjectPool.unit.created", 1, "count", {"pool": "unit"})
```

Metric paths identify the value. Tags add low-cardinality grouping and filtering dimensions such as service, phase, scene, route, or pool. Tags are part of metric identity, so the same path with different tags is tracked as separate metric series.

Use tags for stable grouping values. Use fields for high-cardinality details such as IDs, counts, payload sizes, selected card names, or match IDs.

## Logs, Events, And Traces

Logs and events are explicit. The addon does not hook `print()`, `push_warning()`, or `push_error()` output.

```gdscript
GdObserve.log("warn", "pool exhausted", {"pool": "unit"}, {"available": 0})
GdObserve.event("match.route_loaded", {"route": "match"}, {"match_id": match_id})
```

Timers automatically become frame trace spans. The live stream emits `frame_trace` messages for frames that contain timer spans.

## Live Terminal UI

Start a local metrics WebSocket server from your game:

```gdscript
func _ready() -> void:
	GdObserve.configure(MetricsModule.MetricsConfig.new(true, 500))
	GdObserve.start_live_server(MetricsLiveServer.MetricsLiveServerConfig.new(true, "127.0.0.1", 8765, 250))
```

Runtime monitors are sampled on the snapshot cadence, not every frame. A positive cadence has a 50 ms minimum. A zero or negative cadence disables periodic sampling and broadcast; connection and explicit `snapshot_request` responses still take one fresh sample.

The defaults are disabled at the bootstrap layer and loopback-only at the server layer. Non-loopback binding is rejected unless code explicitly sets `allow_non_loopback=true` and supplies a nonempty runtime token. The client must send `{"type":"auth","token":"..."}` within 5 seconds before the server sends any data. The token is not an exported Resource field and `.env.json` does not load it. The bundled CLI can read it from the process-only `GDOBS_AUTH_TOKEN` environment variable.

For non-loopback clients, `allowed_tag_keys` and `allowed_field_keys` are exact game-payload allowlists; non-allowlisted tag/field entries are omitted. Empty allowlists expose no game tag/field entries. This is an explicit allowlist, **not** a generic promise to detect every possible secret. Callers remain responsible for approving both allowed keys and their values.

The default total metric-series bound is 1,024 across timers, gauges, and counters. Existing identities continue updating at capacity; new identities are rejected (never evicted). Paths, tag keys, and JSON-encoded tag values are limited to 128 UTF-8 bytes and each series to 16 tags. `series_limits` exposes retained, dropped, invalid-identity, and zero eviction counters. Live peers are disconnected before another send when their outbound buffer is at least 1 MiB; `live` exposes drop and disconnect counters.

Then run the terminal UI:

```sh
cd cli
go run . watch --addr ws://127.0.0.1:8765
```

The TUI is mouse-first. Use the top tabs for `Dashboard`, `Logs`, `Events`, and `Traces`; click rows in stream tabs to inspect structured details; use mouse wheel or trackpad scrolling for long views. `ctrl+c` exits the terminal program.

Machine-readable modes:

```sh
cli/bin/gdobs snapshot --url ws://127.0.0.1:8765
cli/bin/gdobs snapshot --env godot_client/.env.json
cli/bin/gdobs status --project .
cli/bin/gdobs snapshot --kind timer --path-prefix CardPresentation --sort p95 --limit 20
cli/bin/gdobs stream --url ws://127.0.0.1:8765
cli/bin/gdobs status --url ws://127.0.0.1:8765
cli/bin/gdobs wait --for event --name match.route_loaded --timeout 10s
cli/bin/gdobs assert --metric BoardVisualService.hex_screen_resolve --max-p95-usec 16666
cli/bin/gdobs assert --budget metrics-budget.json
cli/bin/gdobs diagnose --url ws://127.0.0.1:8765
cli/bin/gdobs capture --duration 30s --out artifacts/run-001
cli/bin/gdobs top timers --file artifacts/run-001/snapshot.json --sort p95 --limit 20
cli/bin/gdobs diff before.json after.json
```

Endpoint resolution order is explicit URL first, then project/env discovery, then `ws://127.0.0.1:8765`. Use `--env path/to/.env.json` or `--project path/to/repo` when running multiple games locally. Supported env keys are `gdobs_url`, or `gdobs_port` with optional `gdobs_host`; `.env` files may also use `GDOBS_URL`, or `GDOBS_PORT` with optional `GDOBS_HOST`. If host is omitted, `gdobs` uses `127.0.0.1`.

The WebSocket protocol is read-only from the CLI perspective. Godot streams `hello`, periodic lightweight `snapshot`, explicit `log`, explicit `event`, and timer-generated `frame_trace` messages. Clients may send `snapshot_request` messages to request filtered read-only snapshots; these do not mutate game state.

Snapshots include custom metrics plus Godot runtime stats from `Performance`, including FPS, frame/process/physics timings, static memory, object/node counts, draw calls, and render memory where supported by the current platform/build. Live snapshots omit raw samples and recent frame traces by default to avoid Godot WebSocket outbound-buffer pressure; request them explicitly with `--raw` or `--traces` when needed.

`capture` writes an agent-friendly artifact bundle:

- `snapshot.json`: filtered snapshot.
- `summary.json`: top timers/counters and runtime summary.
- `diagnose.json`: warnings, tag cardinality, and transport health.
- `status.json`: compact connection/runtime status.
- `metadata.json`: command metadata.
- `summary.md`: human-readable summary.
- `stream.jsonl`: optional live stream when `--duration` is greater than zero.

Budget assertions support JSON files:

```json
{
  "timers": {
    "CardPresentationService.update_display": { "p95_usec": 2000 },
    "HandComponent.update_hand": { "p95_usec": 4000 }
  },
  "runtime": {
    "min_fps": 60,
    "max_frame_usec": 16667,
    "max_orphan_nodes": 400
  }
}
```

## Live Protocol

The WebSocket stream is JSON messages, one object per message. The client is read-only.

`hello`:

```json
{"type":"hello","version":2,"server":"gd-observe","read_only":true}
```

`snapshot`:

```json
{
  "type": "snapshot",
  "version": 2,
  "metric_count": 3,
  "metrics": [{"kind":"timer","path":"svc.op","tags":{"phase":"load"},"p95":1200}],
  "runtime": {"fps":60.0,"frame_delta_usec":16666},
  "recent_frame_traces": []
}
```

`snapshot_request` from client to server:

```json
{
  "type": "snapshot_request",
  "request_id": "agent-1",
  "options": {
    "kind": "timer",
    "path_prefix": "CardPresentation",
    "sort": "p95",
    "limit": 20,
    "include_raw_samples": false,
    "include_traces": false
  }
}
```

The response is a `snapshot` with the same `request_id`.

`log`:

```json
{"type":"log","level":"warn","message":"pool exhausted","tags":{"pool":"unit"},"fields":{"available":0}}
```

`event`:

```json
{"type":"event","name":"match.route_loaded","internal":false,"tags":{"route":"match"},"fields":{"match_id":"abc"}}
```

`frame_trace`:

```json
{"type":"frame_trace","frame":42,"total_usec":3100,"slow":false,"spans":[{"path":"svc.op","duration_usec":3100,"tags":{}}]}
```

## API Surface

- `GdObserve`: addon autoload for game integration.
- `MetricsModule`: RefCounted collector for tests or custom wrappers.
- `MetricsRuntimeSampler`: Godot `Performance` monitor sampler.
- `MetricsLiveServer`: localhost WebSocket snapshot server.
- `cli/`: Go Bubble Tea terminal UI.

Useful `GdObserve` methods include `push_context()`, `pop_context()`, `context_tags()`, `begin_span()`, `checkpoint_runtime()`, `export_snapshot_filtered()`, and `diagnose_metrics()`.

## Notes

- No project settings are required beyond enabling the plugin/autoload.
- Metrics are in-memory only.
- Logs, events, and traces are stream-oriented; connected tools keep their own history.
- The live server is intended for local development/debug builds.

## Repository Layout

- `gd/addon/`: Godot plugin source packaged for GDAM and manual installation.
- `gd/addon/plugin.cfg`: plugin name, version, description, and entry script.
- `gd/addon/src/`: metrics, runtime sampling, live server, editor resources, bootstrap node, and autoload GDScript modules.
- `gd/addon/presets/`: ready-to-use observe and live-server config resources.
- `gd/addon/examples/`: editor-first example scenes.
- `gd/tests/`: Godot test project/scripts for addon behavior.
- `cli/`: Go command-line tools for watching, capturing, asserting, and diffing live metric streams.
- `.github/workflows/ci.yml`: runs Go and reachable Godot 4.7.2 tests, gate controls, and exact-package lifecycle checks.
- `.github/workflows/release.yml`: reruns that common gate before creating addon or CLI GitHub releases.

## Versioning And Releases

This repo has two release targets:

- `gd`: uses `gd-v*` tags, verifies `gd/addon/plugin.cfg`, and publishes the exact common-gate `@aviorstudio_gd-observe.zip` bytes to GitHub and GDAM without rebuilding.
- `cli`: uses `cli-v*` tags, runs Go tests, builds `gdobs` binaries for Linux, macOS, and Windows, and attaches checksums.

The Godot addon version lives in `gd/addon/plugin.cfg`. The release workflow is manual and must be run from `main` with a `patch`, `minor`, or `major` bump.

## Testing

Run locally with:

```sh
mise exec -- ./gd/tests/test.sh
mise exec -- ./gd/tests/test_runner_controls.sh
cd cli && mise exec -- go test ./...
./scripts/build-addon-package.sh
mise exec -- ./scripts/verify-package.sh
mise exec -- ./scripts/verify-editor-lifecycle.sh
```

**Correction ([fieldsofrevik#147](https://github.com/aviorstudio/fieldsofrevik/issues/147)):** the prior claim that CI ran both suites was false: the common action only ran Go. CI and `gd` release now run the Go suite, reachable Godot 4.7.2 suite, negative/restored runner controls, closed package verification, and the packaged editor lifecycle. Headless editor-script shutdown emits a narrowly allowlisted Godot 4.7.2 RID/resource cleanup diagnostic; all other `ERROR:`, `SCRIPT ERROR:`, and `FAIL:` lines fail the lifecycle gate.

## License

MIT
