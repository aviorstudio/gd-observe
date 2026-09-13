@tool
## Editor-authored metrics capture configuration for GdObserve.
class_name ObserveConfig
extends Resource

const MetricsModuleScript = preload("metrics_module.gd")

@export var enabled: bool = true
@export_range(0, 10000, 1) var max_timer_samples: int = 120
@export var trace_enabled: bool = true
@export var trace_continuous_enabled: bool = true
@export_range(0, 1000000, 1) var trace_slow_frame_threshold_usec: int = 16666
@export_range(0, 10000, 1) var recent_frame_trace_count: int = 120
@export_range(0, 100000, 1) var max_metric_series: int = 1024
@export_range(1, 4096, 1) var max_identity_bytes: int = 128
@export_range(0, 128, 1) var max_tags_per_series: int = 16

func to_metrics_config() -> RefCounted:
	return MetricsModuleScript.MetricsConfig.new(
		enabled,
		max_timer_samples,
		trace_enabled,
		trace_continuous_enabled,
		trace_slow_frame_threshold_usec,
		recent_frame_trace_count,
		max_metric_series,
		max_identity_bytes,
		max_tags_per_series
	)
