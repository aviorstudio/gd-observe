@tool
## Editor-authored live dashboard configuration for GdObserve.
class_name ObserveLiveServerConfig
extends Resource

const MetricsLiveServerScript = preload("metrics_live_server.gd")

@export var enabled: bool = true
@export var host: String = "127.0.0.1"
@export_range(0, 65535, 1) var port: int = 8765
@export_range(50, 60000, 1) var snapshot_interval_msec: int = 250
@export var include_raw_samples: bool = false
@export var include_runtime_stats: bool = true
@export var include_frame_traces: bool = false
@export_range(0, 10000000, 1) var max_snapshot_bytes: int = 900000

func to_live_server_config(overrides: Dictionary = {}) -> RefCounted:
	return MetricsLiveServerScript.MetricsLiveServerConfig.new(
		bool(overrides.get("enabled", enabled)),
		str(overrides.get("host", host)).strip_edges(),
		int(overrides.get("port", port)),
		snapshot_interval_msec,
		include_raw_samples,
		include_runtime_stats,
		include_frame_traces,
		max_snapshot_bytes
	)
