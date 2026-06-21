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

func to_metrics_config() -> RefCounted:
	return MetricsModuleScript.MetricsConfig.new(
		enabled,
		max_timer_samples,
		trace_enabled,
		trace_continuous_enabled,
		trace_slow_frame_threshold_usec,
		recent_frame_trace_count
	)
