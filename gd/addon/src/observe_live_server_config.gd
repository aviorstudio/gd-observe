@tool
## Editor-authored live dashboard configuration for GdObserve.
class_name ObserveLiveServerConfig
extends Resource

const MetricsLiveServerScript = preload("metrics_live_server.gd")

@export var enabled: bool = false
@export var host: String = "127.0.0.1"
@export_range(0, 65535, 1) var port: int = 8765
## Zero disables periodic sampling/broadcast; explicit client requests still respond.
@export_range(0, 60000, 1) var snapshot_interval_msec: int = 250
@export var include_raw_samples: bool = false
@export var include_runtime_stats: bool = true
@export var include_frame_traces: bool = false
@export_range(0, 10000000, 1) var max_snapshot_bytes: int = 900000
@export_range(1, 100000000, 1) var max_client_buffer_bytes: int = 1048576
@export var allow_non_loopback: bool = false
@export_range(1, 60000, 1) var auth_timeout_msec: int = 5000
@export var allowed_tag_keys: PackedStringArray = PackedStringArray()
@export var allowed_field_keys: PackedStringArray = PackedStringArray()

func to_live_server_config(overrides: Dictionary = {}) -> RefCounted:
	return MetricsLiveServerScript.MetricsLiveServerConfig.new(
		bool(overrides.get("enabled", enabled)),
		str(overrides.get("host", host)).strip_edges(),
		int(overrides.get("port", port)),
		snapshot_interval_msec,
		include_raw_samples,
		include_runtime_stats,
		include_frame_traces,
		max_snapshot_bytes,
		max_client_buffer_bytes,
		allow_non_loopback,
		str(overrides.get("auth_token", "")),
		auth_timeout_msec,
		allowed_tag_keys,
		allowed_field_keys
	)
