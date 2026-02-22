class_name MetricsModule
extends RefCounted

class MetricsConfig extends RefCounted:
	var enabled: bool
	var max_samples_per_metric: int

	func _init(enabled: bool = true, max_samples_per_metric: int = 60) -> void:
		self.enabled = enabled
		self.max_samples_per_metric = max_samples_per_metric

class MetricsSummary extends RefCounted:
	var count: int = 0
	var total_usec: int = 0
	var min_usec: int = 0
	var max_usec: int = 0
	var avg_usec: float = 0.0
	var p50_usec: int = 0
	var p95_usec: int = 0
	var p99_usec: int = 0

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

func get_summary(service_name: String, metric_name: String) -> MetricsSummary:
	var summary := MetricsSummary.new()
	if not _config.enabled:
		return summary

	var service_metrics: Dictionary = _metrics.get(service_name, {})
	var raw_samples: Variant = service_metrics.get(metric_name, [])
	var samples: Array[int] = []
	if raw_samples is Array:
		for sample in raw_samples:
			samples.append(int(sample))

	if samples.is_empty():
		return summary

	samples.sort()
	summary.count = samples.size()
	summary.min_usec = samples[0]
	summary.max_usec = samples[samples.size() - 1]
	for sample in samples:
		summary.total_usec += sample
	summary.avg_usec = float(summary.total_usec) / float(summary.count)
	summary.p50_usec = _percentile(samples, 0.50)
	summary.p95_usec = _percentile(samples, 0.95)
	summary.p99_usec = _percentile(samples, 0.99)
	return summary

func get_all_summaries() -> Dictionary[String, Dictionary]:
	var result: Dictionary[String, Dictionary] = {}
	if not _config.enabled:
		return result

	for service_name in _metrics.keys():
		var service_metrics: Dictionary = _metrics.get(service_name, {})
		var metric_summaries: Dictionary = {}
		for metric_name in service_metrics.keys():
			metric_summaries[metric_name] = get_summary(service_name, metric_name)
		result[service_name] = metric_summaries

	return result

func reset(service_name: String = "") -> void:
	if service_name.is_empty():
		_metrics.clear()
		return
	if _metrics.has(service_name):
		_metrics.erase(service_name)

func clear() -> void:
	_metrics.clear()

func _percentile(sorted_samples: Array[int], percentile: float) -> int:
	if sorted_samples.is_empty():
		return 0
	var clamped: float = clampf(percentile, 0.0, 1.0)
	var index: int = int(ceil(clamped * float(sorted_samples.size()))) - 1
	index = maxi(index, 0)
	index = mini(index, sorted_samples.size() - 1)
	return sorted_samples[index]

