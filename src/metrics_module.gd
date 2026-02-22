class_name MetricsModule
extends RefCounted

class MetricsConfig extends RefCounted:
	var enabled: bool
	var max_samples_per_metric: int

	func _init(enabled: bool = true, max_samples_per_metric: int = 60) -> void:
		self.enabled = enabled
		self.max_samples_per_metric = max_samples_per_metric

var _config: MetricsConfig = MetricsConfig.new()
var _metrics: Dictionary = {}

func configure(config: MetricsConfig) -> void:
	_config = config if config else MetricsConfig.new()

func begin_timer(metrics_enabled: bool) -> int:
	if not _config.enabled or not metrics_enabled:
		return -1
	return Time.get_ticks_usec()

func record(
	service_name: String,
	metric_name: String,
	duration_usec: int
) -> void:
	if not _config.enabled or duration_usec < 0:
		return

	var service_metrics: Dictionary = _metrics.get(service_name, {})
	var raw_samples: Variant = service_metrics.get(metric_name, [])
	var metric_samples: Array[int] = []
	if raw_samples is Array:
		for sample in raw_samples:
			metric_samples.append(int(sample))
	metric_samples.append(duration_usec)

	var max_samples: int = max(_config.max_samples_per_metric, 0)
	if max_samples > 0:
		while metric_samples.size() > max_samples:
			metric_samples.pop_front()

	service_metrics[metric_name] = metric_samples
	_metrics[service_name] = service_metrics

func finish_void(
	recorder: Object,
	service_name: String,
	metric_name: String,
	start_time_usec: int
) -> void:
	if start_time_usec < 0:
		return
	record(service_name, metric_name, Time.get_ticks_usec() - start_time_usec)

func finish_array(
	recorder: Object,
	service_name: String,
	metric_name: String,
	start_time_usec: int,
	result: Array
) -> Array:
	finish_void(recorder, service_name, metric_name, start_time_usec)
	return result

func get_metrics() -> Dictionary:
	if not _config.enabled:
		return {}
	return _metrics.duplicate(true)

func clear() -> void:
	_metrics.clear()

