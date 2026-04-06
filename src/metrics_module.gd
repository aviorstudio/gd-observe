## In-memory metrics sampler and aggregation helper.
class_name MetricsModule
extends RefCounted

## Runtime metrics configuration.
class MetricsConfig extends RefCounted:
	## Enables/disables metric capture.
	var enabled: bool
	## Maximum retained samples per service/metric stream.
	var max_samples_per_metric: int

	func _init(enabled: bool = true, max_samples_per_metric: int = 60) -> void:
		self.enabled = enabled
		self.max_samples_per_metric = max_samples_per_metric

## Aggregated metrics summary for a single metric stream.
class MetricsSummary extends RefCounted:
	## Number of captured samples.
	var count: int = 0
	## Sum of all captured sample durations in microseconds.
	var total_usec: int = 0
	## Minimum observed duration in microseconds.
	var min_usec: int = 0
	## Maximum observed duration in microseconds.
	var max_usec: int = 0
	## Average observed duration in microseconds.
	var avg_usec: float = 0.0
	## 50th percentile duration in microseconds.
	var p50: int = 0
	## 95th percentile duration in microseconds.
	var p95: int = 0
	## 99th percentile duration in microseconds.
	var p99: int = 0

var _config: MetricsConfig = MetricsConfig.new()
var _metrics: Dictionary[String, Dictionary] = {}

## Applies runtime metrics configuration.
func configure(config: MetricsConfig) -> void:
	_config = config if config else MetricsConfig.new()

## Returns whether metrics capture is enabled.
func is_enabled() -> bool:
	return _config.enabled

## Starts a timer for a call site and returns the current microsecond timestamp.
##
## Returns `-1` when capture is disabled for this call site.
func begin_timer(metrics_enabled: bool) -> int:
	if not _config.enabled or not metrics_enabled:
		return -1
	return Time.get_ticks_usec()

## Records one metric sample duration.
func record(
	service_name: String,
	metric_name: String,
	duration_usec: int
) -> void:
	if not _config.enabled or duration_usec < 0:
		return

	if not _metrics.has(service_name):
		_metrics[service_name] = {}
	var service_metrics: Dictionary = _metrics[service_name]
	if not service_metrics.has(metric_name):
		service_metrics[metric_name] = [] as Array[int]
	var metric_samples: Array[int] = service_metrics[metric_name]
	metric_samples.append(duration_usec)

	var max_samples: int = max(_config.max_samples_per_metric, 0)
	if max_samples > 0:
		while metric_samples.size() > max_samples:
			metric_samples.pop_front()

	service_metrics[metric_name] = metric_samples

## Finishes a timer and records the elapsed microseconds.
func finish_void(
	recorder: Object,
	service_name: String,
	metric_name: String,
	start_time_usec: int
) -> void:
	if start_time_usec < 0:
		return
	record(service_name, metric_name, Time.get_ticks_usec() - start_time_usec)

## Finishes a timer, records elapsed time, and returns the provided array value.
func finish_array(
	recorder: Object,
	service_name: String,
	metric_name: String,
	start_time_usec: int,
	result: Array
) -> Array:
	finish_void(recorder, service_name, metric_name, start_time_usec)
	return result

## Finishes a timer, records elapsed time, and returns the provided value unchanged.
func finish_and_return(
	start_time_usec: int,
	service_name: String,
	metric_name: String,
	value: Variant
) -> Variant:
	if start_time_usec >= 0:
		record(service_name, metric_name, Time.get_ticks_usec() - start_time_usec)
	return value

## Returns a deep copy of all recorded raw metric samples.
func get_metrics() -> Dictionary:
	if not _config.enabled:
		return {}
	return _metrics.duplicate(true)

## Returns an aggregate summary for one service/metric stream.
func get_summary(service_name: String, metric_name: String) -> MetricsSummary:
	var summary := MetricsSummary.new()
	if not _config.enabled:
		return summary
	if not _metrics.has(service_name):
		return summary
	var service_metrics: Dictionary = _metrics[service_name]
	if not service_metrics.has(metric_name):
		return summary

	var samples: Array[int] = service_metrics[metric_name]
	if samples.is_empty():
		return summary

	var sorted_samples: Array[int] = []
	sorted_samples.assign(samples)
	sorted_samples.sort()
	summary.count = sorted_samples.size()
	summary.min_usec = sorted_samples[0]
	summary.max_usec = sorted_samples[sorted_samples.size() - 1]
	for sample in sorted_samples:
		summary.total_usec += sample
	summary.avg_usec = float(summary.total_usec) / float(summary.count)
	summary.p50 = _percentile(sorted_samples, 0.50)
	summary.p95 = _percentile(sorted_samples, 0.95)
	summary.p99 = _percentile(sorted_samples, 0.99)
	return summary

## Returns aggregate summaries for every service/metric stream.
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

## Clears metrics for one service, or for all services when empty.
func reset(service_name: String = "") -> void:
	if service_name.is_empty():
		_metrics.clear()
		return
	if _metrics.has(service_name):
		_metrics.erase(service_name)

## Clears all stored metrics.
func clear() -> void:
	_metrics.clear()

## Returns all summaries as an exportable array of flat dictionaries.
func export_summaries() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var all: Dictionary[String, Dictionary] = get_all_summaries()
	for service_name: String in all:
		var service_metrics: Dictionary = all[service_name]
		for metric_name: String in service_metrics:
			var summary: MetricsSummary = service_metrics[metric_name]
			result.append({
				"service": service_name,
				"metric": metric_name,
				"count": summary.count,
				"total_usec": summary.total_usec,
				"min_usec": summary.min_usec,
				"max_usec": summary.max_usec,
				"avg_usec": summary.avg_usec,
			})
	return result

## Serializes all metric summaries to JSON and writes to a file.
func export_to_file(file_path: String) -> bool:
	var summaries: Array[Dictionary] = export_summaries()
	var json_string: String = JSON.stringify(summaries, "\t")
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(json_string)
	file.close()
	return true

func _percentile(sorted_samples: Array[int], percentile: float) -> int:
	if sorted_samples.is_empty():
		return 0
	var clamped: float = clampf(percentile, 0.0, 1.0)
	var index: int = int(ceil(clamped * float(sorted_samples.size()))) - 1
	index = maxi(index, 0)
	index = mini(index, sorted_samples.size() - 1)
	return sorted_samples[index]

