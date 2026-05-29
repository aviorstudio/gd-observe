## In-memory local observability collector for Godot projects.
class_name MetricsModule
extends RefCounted

signal log_recorded(entry: Dictionary)
signal event_recorded(entry: Dictionary)
signal frame_trace_recorded(trace: Dictionary)

const KIND_TIMER: String = "timer"
const KIND_GAUGE: String = "gauge"
const KIND_COUNTER: String = "counter"
const UNIT_USEC: String = "usec"
const UNIT_COUNT: String = "count"
const UNIT_VALUE: String = "value"
const EVENT_INTERNAL_PREFIX: String = "gd_observe."

## Runtime metrics configuration.
class MetricsConfig extends RefCounted:
	## Enables/disables metric capture.
	var enabled: bool
	## Maximum retained samples per timer path.
	var max_timer_samples: int
	## Emits frame traces from recorded timers.
	var trace_enabled: bool
	## Emits every frame trace that contains spans.
	var trace_continuous_enabled: bool
	## Always emits traces whose total span time crosses this threshold.
	var trace_slow_frame_threshold_usec: int
	## Maximum recent frame traces included in snapshots.
	var recent_frame_trace_count: int

	func _init(
		p_enabled: bool = true,
		p_max_timer_samples: int = 120,
		p_trace_enabled: bool = true,
		p_trace_continuous_enabled: bool = true,
		p_trace_slow_frame_threshold_usec: int = 16666,
		p_recent_frame_trace_count: int = 120
	) -> void:
		enabled = p_enabled
		max_timer_samples = p_max_timer_samples
		trace_enabled = p_trace_enabled
		trace_continuous_enabled = p_trace_continuous_enabled
		trace_slow_frame_threshold_usec = p_trace_slow_frame_threshold_usec
		recent_frame_trace_count = p_recent_frame_trace_count

class MetricsSpan extends RefCounted:
	var _metrics: MetricsModule = null
	var path: String = ""
	var start_time_usec: int = -1
	var tags: Dictionary = {}
	var checkpoints: Array[Dictionary] = []
	var finished: bool = false

	func _init(p_metrics: MetricsModule, p_path: String, p_tags: Dictionary = {}) -> void:
		_metrics = p_metrics
		path = p_path
		tags = p_tags.duplicate(true)
		start_time_usec = Time.get_ticks_usec()

	func checkpoint(name: String, extra_tags: Dictionary = {}, fields: Dictionary = {}) -> Dictionary[String, Variant]:
		if finished or _metrics == null:
			return {}
		var elapsed_usec: int = Time.get_ticks_usec() - start_time_usec
		var checkpoint_tags: Dictionary = tags.duplicate(true)
		for key in extra_tags:
			checkpoint_tags[key] = extra_tags[key]
		checkpoint_tags["checkpoint"] = name
		var checkpoint_fields: Dictionary = fields.duplicate(true)
		checkpoint_fields["elapsed_usec"] = elapsed_usec
		var entry: Dictionary[String, Variant] = {
			"name": name,
			"elapsed_usec": elapsed_usec,
			"tags": checkpoint_tags.duplicate(true),
			"fields": checkpoint_fields.duplicate(true),
		}
		checkpoints.append(entry)
		_metrics.record_timer(path + ".checkpoint", elapsed_usec, checkpoint_tags)
		_metrics.event("gd_observe.span_checkpoint", checkpoint_tags, checkpoint_fields)
		return entry

	func finish(extra_tags: Dictionary = {}, fields: Dictionary = {}) -> int:
		if finished or _metrics == null:
			return 0
		finished = true
		var finish_tags: Dictionary = tags.duplicate(true)
		for key in extra_tags:
			finish_tags[key] = extra_tags[key]
		var duration_usec: int = Time.get_ticks_usec() - start_time_usec
		_metrics.record_timer(path, duration_usec, finish_tags)
		var event_fields: Dictionary = fields.duplicate(true)
		event_fields["duration_usec"] = duration_usec
		event_fields["checkpoint_count"] = checkpoints.size()
		_metrics.event("gd_observe.span_finished", finish_tags, event_fields)
		return duration_usec

var _config: MetricsConfig = MetricsConfig.new()
var _timers: Dictionary[String, Dictionary] = {}
var _gauges: Dictionary[String, Dictionary] = {}
var _counters: Dictionary[String, Dictionary] = {}
var _trace_frame_id: int = -1
var _trace_spans: Array[Dictionary] = []
var _recent_frame_traces: Array[Dictionary] = []
var _trigger_trace_frames_remaining: int = 0
var _context_stack: Array[Dictionary] = []
var _runtime_checkpoints: Dictionary[String, Dictionary] = {}

## Applies runtime metrics configuration.
func configure(config: MetricsConfig) -> void:
	_config = config if config != null else MetricsConfig.new()

## Returns whether metrics capture is enabled.
func is_enabled() -> bool:
	return _config.enabled

## Starts a timer and returns the current microsecond timestamp, or -1 when disabled.
func begin_timer() -> int:
	if not _config.enabled:
		return -1
	return Time.get_ticks_usec()

func push_context(tags: Dictionary) -> Dictionary[String, Variant]:
	var normalized: Dictionary[String, Variant] = _normalize_tags(tags)
	_context_stack.append(normalized)
	return context_tags()

func pop_context() -> Dictionary[String, Variant]:
	if not _context_stack.is_empty():
		_context_stack.pop_back()
	return context_tags()

func clear_context() -> void:
	_context_stack.clear()

func set_context(tags: Dictionary) -> void:
	_context_stack.clear()
	push_context(tags)

func context_tags(extra_tags: Dictionary = {}) -> Dictionary[String, Variant]:
	var merged: Dictionary[String, Variant] = {}
	for context: Dictionary in _context_stack:
		for key in context:
			merged[key] = context[key]
	var normalized_extra: Dictionary[String, Variant] = _normalize_tags(extra_tags)
	for key in normalized_extra:
		merged[key] = normalized_extra[key]
	return merged

func begin_span(path: String, tags: Dictionary = {}) -> MetricsSpan:
	return MetricsSpan.new(self, _normalize_path(path), context_tags(tags))

## Records elapsed microseconds for a timer path and optional low-cardinality tags.
func record_timer(path: String, duration_usec: int, tags: Dictionary = {}) -> void:
	if not _config.enabled or duration_usec < 0:
		return
	var normalized_path: String = _normalize_path(path)
	if normalized_path.is_empty():
		return
	var normalized_tags: Dictionary[String, Variant] = context_tags(tags)
	var key: String = _metric_key(normalized_path, normalized_tags)
	var timer: Dictionary = _timers.get(key, {
		"key": key,
		"path": normalized_path,
		"tags": normalized_tags,
		"samples": [],
	})
	var samples: Array = timer.get("samples", [])
	samples.append(duration_usec)
	var max_samples: int = maxi(_config.max_timer_samples, 0)
	if max_samples > 0 and samples.size() > max_samples:
		samples = samples.slice(samples.size() - max_samples)
	timer["samples"] = samples
	timer["last_updated_usec"] = Time.get_ticks_usec()
	timer["summary_dirty"] = true
	_timers[key] = timer
	_record_trace_span(normalized_path, duration_usec, normalized_tags)

## Finishes a timer and records elapsed microseconds for a timer path.
func finish_timer(path: String, start_time_usec: int, tags: Dictionary = {}) -> void:
	if start_time_usec < 0:
		return
	record_timer(path, Time.get_ticks_usec() - start_time_usec, tags)

## Finishes a timer, records elapsed time, and returns the provided value unchanged.
func finish_and_return(path: String, start_time_usec: int, value: Variant, tags: Dictionary = {}) -> Variant:
	finish_timer(path, start_time_usec, tags)
	return value

## Sets a gauge path to the latest numeric value.
func set_gauge(path: String, value: float, unit: String = UNIT_VALUE, tags: Dictionary = {}) -> void:
	if not _config.enabled:
		return
	var normalized_path: String = _normalize_path(path)
	if normalized_path.is_empty():
		return
	var normalized_tags: Dictionary[String, Variant] = context_tags(tags)
	var key: String = _metric_key(normalized_path, normalized_tags)
	var now_usec: int = Time.get_ticks_usec()
	var gauge: Dictionary = _gauges.get(key, {
		"key": key,
		"path": normalized_path,
		"tags": normalized_tags,
		"kind": KIND_GAUGE,
		"unit": unit,
		"count": 0,
		"min": value,
		"max": value,
		"latest": value,
		"last_updated_usec": now_usec,
	})
	gauge["unit"] = unit
	gauge["count"] = int(gauge.get("count", 0)) + 1
	gauge["latest"] = value
	gauge["min"] = minf(float(gauge.get("min", value)), value)
	gauge["max"] = maxf(float(gauge.get("max", value)), value)
	gauge["last_updated_usec"] = now_usec
	_gauges[key] = gauge

## Increments a counter path by amount.
func increment_counter(path: String, amount: float = 1.0, unit: String = UNIT_COUNT, tags: Dictionary = {}) -> void:
	if not _config.enabled:
		return
	var normalized_path: String = _normalize_path(path)
	if normalized_path.is_empty():
		return
	var normalized_tags: Dictionary[String, Variant] = context_tags(tags)
	var key: String = _metric_key(normalized_path, normalized_tags)
	var now_usec: int = Time.get_ticks_usec()
	var counter: Dictionary = _counters.get(key, {
		"key": key,
		"path": normalized_path,
		"tags": normalized_tags,
		"kind": KIND_COUNTER,
		"unit": unit,
		"count": 0,
		"value": 0.0,
		"latest_delta": 0.0,
		"last_updated_usec": now_usec,
	})
	counter["unit"] = unit
	counter["count"] = int(counter.get("count", 0)) + 1
	counter["value"] = float(counter.get("value", 0.0)) + amount
	counter["latest_delta"] = amount
	counter["last_updated_usec"] = now_usec
	_counters[key] = counter

## Emits an explicit structured log entry. Tags are low-cardinality filters; fields hold details.
func log(level: String, message: String, tags: Dictionary = {}, fields: Dictionary = {}) -> Dictionary[String, Variant]:
	if not _config.enabled:
		return {}
	var entry: Dictionary[String, Variant] = {
		"type": "log",
		"timestamp_usec": Time.get_ticks_usec(),
		"level": _normalize_level(level),
		"message": message,
		"tags": context_tags(tags),
		"fields": fields.duplicate(true),
	}
	log_recorded.emit(entry.duplicate(true))
	return entry

## Emits an explicit structured event entry. Tags are low-cardinality filters; fields hold details.
func event(name: String, tags: Dictionary = {}, fields: Dictionary = {}) -> Dictionary[String, Variant]:
	if not _config.enabled:
		return {}
	var normalized_name: String = _normalize_path(name)
	if normalized_name.is_empty():
		return {}
	var entry: Dictionary[String, Variant] = {
		"type": "event",
		"timestamp_usec": Time.get_ticks_usec(),
		"name": normalized_name,
		"tags": context_tags(tags),
		"fields": fields.duplicate(true),
		"internal": normalized_name.begins_with(EVENT_INTERNAL_PREFIX),
	}
	event_recorded.emit(entry.duplicate(true))
	return entry

## Captures the next frame_count traces even when continuous trace streaming is disabled.
func capture_trace_frames(frame_count: int) -> void:
	_trigger_trace_frames_remaining = maxi(_trigger_trace_frames_remaining, maxi(frame_count, 0))
	event("gd_observe.trace_capture_requested", {}, {"frames": frame_count})

func checkpoint_runtime(name: String, runtime_snapshot: Dictionary = {}, tags: Dictionary = {}) -> Dictionary[String, Variant]:
	var normalized_name: String = _normalize_path(name)
	if normalized_name.is_empty():
		return {}
	var checkpoint: Dictionary[String, Variant] = {
		"name": normalized_name,
		"timestamp_usec": Time.get_ticks_usec(),
		"tags": context_tags(tags),
		"runtime": runtime_snapshot.duplicate(true),
	}
	_runtime_checkpoints[normalized_name] = checkpoint.duplicate(true)
	event("gd_observe.runtime_checkpoint", {"checkpoint": normalized_name}, {"runtime": runtime_snapshot.duplicate(true)})
	return checkpoint

## Returns one timer summary dictionary, or an empty dictionary when absent.
func get_timer_summary(path: String, tags: Dictionary = {}) -> Dictionary[String, Variant]:
	var normalized_path: String = _normalize_path(path)
	var key: String = _metric_key(normalized_path, _normalize_tags(tags))
	if not _config.enabled or not _timers.has(key):
		return {}
	return _build_timer_summary(_timers[key])

## Returns all metric rows as JSON-friendly dictionaries.
func export_metrics(include_raw_samples: bool = false) -> Array[Dictionary]:
	return export_metrics_filtered({"include_raw_samples": include_raw_samples})

func export_metrics_filtered(options: Dictionary = {}) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not _config.enabled:
		return result
	var include_raw_samples: bool = bool(options.get("include_raw_samples", false))
	for key: String in _timers.keys():
		var timer: Dictionary = _timers[key]
		var summary: Dictionary[String, Variant] = _build_timer_summary(timer)
		if include_raw_samples:
			summary["samples"] = Array(timer.get("samples", [])).duplicate(true)
		_append_metric_if_matches(result, summary, options)
	for key: String in _gauges.keys():
		_append_metric_if_matches(result, _gauges[key].duplicate(true), options)
	for key: String in _counters.keys():
		_append_metric_if_matches(result, _counters[key].duplicate(true), options)
	_sort_metrics(result, str(options.get("sort", "")))
	var limit: int = int(options.get("limit", 0))
	if limit > 0 and result.size() > limit:
		result = result.slice(0, limit)
	return result

## Returns a JSON-friendly live snapshot for tools such as terminal dashboards.
func export_snapshot(include_raw_samples: bool = false) -> Dictionary[String, Variant]:
	return export_snapshot_filtered({"include_raw_samples": include_raw_samples})

func export_snapshot_filtered(options: Dictionary = {}) -> Dictionary[String, Variant]:
	var metrics: Array[Dictionary] = export_metrics_filtered(options)
	var timer_count: int = 0
	var gauge_count: int = 0
	var counter_count: int = 0
	var sample_count: int = 0
	for metric: Dictionary in metrics:
		match str(metric.get("kind", "")):
			KIND_TIMER:
				timer_count += 1
				sample_count += int(metric.get("count", 0))
			KIND_GAUGE:
				gauge_count += 1
			KIND_COUNTER:
				counter_count += 1
	var include_traces: bool = bool(options.get("include_traces", true))
	var snapshot: Dictionary[String, Variant] = {
		"version": 2,
		"timestamp_usec": Time.get_ticks_usec(),
		"enabled": _config.enabled,
		"metric_count": metrics.size(),
		"timer_count": timer_count,
		"gauge_count": gauge_count,
		"counter_count": counter_count,
		"sample_count": sample_count,
		"metrics": metrics,
		"summary": build_summary(metrics, options),
		"runtime_checkpoints": _runtime_checkpoints.duplicate(true),
		"runtime_deltas": _build_runtime_deltas(),
	}
	if include_traces:
		snapshot["recent_frame_traces"] = _recent_frame_traces.duplicate(true)
	else:
		snapshot["recent_frame_traces"] = []
	return snapshot

func build_summary(metrics: Array = [], options: Dictionary = {}) -> Dictionary[String, Variant]:
	var rows: Array = metrics if not metrics.is_empty() else export_metrics_filtered(options)
	var limit: int = int(options.get("summary_limit", 10))
	return {
		"top_timers_by_p95": _top_metrics(rows, KIND_TIMER, "p95", limit),
		"top_timers_by_total": _top_metrics(rows, KIND_TIMER, "total", limit),
		"top_counters": _top_metrics(rows, KIND_COUNTER, "value", limit),
		"tag_cardinality": _tag_cardinality(rows),
		"warnings": diagnose(metrics),
	}

func diagnose(metrics: Array = []) -> Array[String]:
	var rows: Array = metrics if not metrics.is_empty() else export_metrics_filtered({})
	var warnings: Array[String] = []
	if not _config.enabled:
		warnings.append("metrics capture is disabled")
	if rows.is_empty():
		warnings.append("no custom metrics have been recorded")
	var cardinality: Dictionary = _tag_cardinality(rows)
	for tag_name: String in cardinality.keys():
		var values: int = int(cardinality[tag_name])
		if values > 25:
			warnings.append("tag '%s' has high cardinality: %d values; consider fields instead" % [tag_name, values])
	var retained_samples: int = 0
	for row in rows:
		if row is Dictionary and str(row.get("kind", "")) == KIND_TIMER:
			retained_samples += int(row.get("count", 0))
	if retained_samples > 2000:
		warnings.append("large retained timer sample volume: %d; prefer filtered snapshots for CLI workflows" % retained_samples)
	if _recent_frame_traces.size() > 80:
		warnings.append("many recent frame traces retained: %d; omit traces from live snapshots unless needed" % _recent_frame_traces.size())
	return warnings

## Clears metrics for one path, or all paths when empty.
func reset(path: String = "", tags: Dictionary = {}) -> void:
	var normalized_path: String = _normalize_path(path)
	if normalized_path.is_empty():
		_timers.clear()
		_gauges.clear()
		_counters.clear()
		_trace_spans.clear()
		_recent_frame_traces.clear()
		_runtime_checkpoints.clear()
		_trace_frame_id = -1
		event("gd_observe.reset", {}, {"scope": "all"})
		return
	var normalized_tags: Dictionary[String, Variant] = _normalize_tags(tags)
	var key: String = _metric_key(normalized_path, normalized_tags)
	_timers.erase(key)
	_gauges.erase(key)
	_counters.erase(key)
	event("gd_observe.reset", normalized_tags, {"path": normalized_path})

## Clears all stored metrics.
func clear() -> void:
	reset()

## Serializes the current snapshot to JSON and writes to a file.
func export_to_file(file_path: String, include_raw_samples: bool = false) -> bool:
	var json_string: String = JSON.stringify(export_snapshot(include_raw_samples), "\t")
	var file := FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(json_string)
	file.close()
	return true

func flush_frame_trace() -> Dictionary[String, Variant]:
	return _flush_frame_trace(false)

func _append_metric_if_matches(result: Array[Dictionary], metric: Dictionary, options: Dictionary) -> void:
	var kind: String = str(options.get("kind", ""))
	if not kind.is_empty() and str(metric.get("kind", "")) != kind:
		return
	var path: String = str(options.get("path", ""))
	if not path.is_empty() and str(metric.get("path", "")) != path:
		return
	var path_prefix: String = str(options.get("path_prefix", ""))
	if not path_prefix.is_empty() and not str(metric.get("path", "")).begins_with(path_prefix):
		return
	var tag_filters: Dictionary = options.get("tags", {})
	if tag_filters is Dictionary and not tag_filters.is_empty():
		var metric_tags: Dictionary = metric.get("tags", {})
		for key in tag_filters:
			if str(metric_tags.get(key, "")) != str(tag_filters[key]):
				return
	result.append(metric)

func _sort_metrics(metrics: Array[Dictionary], field: String) -> void:
	if field.is_empty():
		return
	metrics.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get(field, 0.0)) > float(b.get(field, 0.0))
	)

func _top_metrics(metrics: Array, kind: String, field: String, limit: int) -> Array[Dictionary]:
	var filtered: Array[Dictionary] = []
	for metric in metrics:
		if metric is Dictionary and str(metric.get("kind", "")) == kind:
			filtered.append(metric.duplicate(true))
	_sort_metrics(filtered, field)
	if limit > 0 and filtered.size() > limit:
		filtered = filtered.slice(0, limit)
	return filtered

func _tag_cardinality(metrics: Array) -> Dictionary[String, int]:
	var values_by_tag: Dictionary[String, Dictionary] = {}
	for metric in metrics:
		if not metric is Dictionary:
			continue
		var tags: Dictionary = metric.get("tags", {})
		for tag_name in tags:
			var normalized_tag: String = str(tag_name)
			if not values_by_tag.has(normalized_tag):
				values_by_tag[normalized_tag] = {}
			values_by_tag[normalized_tag][str(tags[tag_name])] = true
	var result: Dictionary[String, int] = {}
	for tag_name: String in values_by_tag.keys():
		result[tag_name] = values_by_tag[tag_name].size()
	return result

func _build_runtime_deltas() -> Array[Dictionary]:
	var names: Array[String] = []
	for name: String in _runtime_checkpoints.keys():
		names.append(name)
	names.sort_custom(func(a: String, b: String) -> bool:
		return int(_runtime_checkpoints[a].get("timestamp_usec", 0)) < int(_runtime_checkpoints[b].get("timestamp_usec", 0))
	)
	var deltas: Array[Dictionary] = []
	for i in range(1, names.size()):
		var from_checkpoint: Dictionary = _runtime_checkpoints[names[i - 1]]
		var to_checkpoint: Dictionary = _runtime_checkpoints[names[i]]
		var from_runtime: Dictionary = from_checkpoint.get("runtime", {})
		var to_runtime: Dictionary = to_checkpoint.get("runtime", {})
		var delta_values: Dictionary = {}
		for key in to_runtime:
			if from_runtime.has(key) and (to_runtime[key] is int or to_runtime[key] is float) and (from_runtime[key] is int or from_runtime[key] is float):
				delta_values[key] = float(to_runtime[key]) - float(from_runtime[key])
		deltas.append({
			"from": names[i - 1],
			"to": names[i],
			"delta": delta_values,
		})
	return deltas

func _build_timer_summary(timer: Dictionary) -> Dictionary[String, Variant]:
	if not bool(timer.get("summary_dirty", true)) and timer.has("summary"):
		var cached_summary: Dictionary = timer.get("summary", {})
		return cached_summary.duplicate(true)
	var samples: Array = timer.get("samples", [])
	if samples.is_empty():
		return {}
	var sorted_samples: Array[int] = []
	for sample in samples:
		sorted_samples.append(int(sample))
	sorted_samples.sort()
	var total_usec: int = 0
	for sample: int in sorted_samples:
		total_usec += sample
	var metric_tags: Dictionary = timer.get("tags", {})
	var summary: Dictionary[String, Variant] = {
		"key": str(timer.get("key", "")),
		"path": str(timer.get("path", "")),
		"tags": metric_tags.duplicate(true),
		"kind": KIND_TIMER,
		"unit": UNIT_USEC,
		"count": sorted_samples.size(),
		"total": total_usec,
		"min": sorted_samples[0],
		"max": sorted_samples[sorted_samples.size() - 1],
		"avg": float(total_usec) / float(sorted_samples.size()),
		"p50": _percentile(sorted_samples, 0.50),
		"p95": _percentile(sorted_samples, 0.95),
		"p99": _percentile(sorted_samples, 0.99),
		"latest": int(samples[samples.size() - 1]),
		"last_updated_usec": int(timer.get("last_updated_usec", Time.get_ticks_usec())),
	}
	timer["summary"] = summary.duplicate(true)
	timer["summary_dirty"] = false
	return summary

func _percentile(sorted_samples: Array[int], percentile: float) -> int:
	if sorted_samples.is_empty():
		return 0
	var clamped: float = clampf(percentile, 0.0, 1.0)
	var index: int = int(ceil(clamped * float(sorted_samples.size()))) - 1
	index = maxi(index, 0)
	index = mini(index, sorted_samples.size() - 1)
	return sorted_samples[index]

func _normalize_path(path: String) -> String:
	return path.strip_edges().replace(" ", "_")

func _normalize_tags(tags: Dictionary) -> Dictionary[String, Variant]:
	var normalized: Dictionary[String, Variant] = {}
	for raw_key: Variant in tags.keys():
		var key: String = _normalize_path(str(raw_key))
		if key.is_empty():
			continue
		normalized[key] = tags[raw_key]
	return normalized

func _metric_key(path: String, tags: Dictionary) -> String:
	if tags.is_empty():
		return path
	var keys: Array[String] = []
	for key: String in tags.keys():
		keys.append(key)
	keys.sort()
	var parts: Array[String] = []
	for key: String in keys:
		parts.append("%s=%s" % [key, JSON.stringify(tags[key])])
	return path + "|" + ",".join(parts)

func _normalize_level(level: String) -> String:
	var normalized: String = level.strip_edges().to_lower()
	if normalized in ["debug", "info", "warn", "error"]:
		return normalized
	return "info"

func _record_trace_span(path: String, duration_usec: int, tags: Dictionary[String, Variant]) -> void:
	if not _config.trace_enabled:
		return
	var frame_id: int = Engine.get_process_frames()
	if _trace_frame_id == -1:
		_trace_frame_id = frame_id
	elif frame_id != _trace_frame_id:
		_flush_frame_trace(false)
		_trace_frame_id = frame_id
	_trace_spans.append({
		"path": path,
		"tags": tags.duplicate(true),
		"duration_usec": duration_usec,
		"timestamp_usec": Time.get_ticks_usec(),
	})

func _flush_frame_trace(force: bool) -> Dictionary[String, Variant]:
	if _trace_spans.is_empty():
		return {}
	var total_usec: int = 0
	for span: Dictionary in _trace_spans:
		total_usec += int(span.get("duration_usec", 0))
	var should_emit: bool = force or _config.trace_continuous_enabled or total_usec >= _config.trace_slow_frame_threshold_usec or _trigger_trace_frames_remaining > 0
	var trace: Dictionary[String, Variant] = {
		"type": "frame_trace",
		"timestamp_usec": Time.get_ticks_usec(),
		"frame": _trace_frame_id,
		"span_count": _trace_spans.size(),
		"total_usec": total_usec,
		"slow": total_usec >= _config.trace_slow_frame_threshold_usec,
		"spans": _trace_spans.duplicate(true),
	}
	_trace_spans.clear()
	if _trigger_trace_frames_remaining > 0:
		_trigger_trace_frames_remaining -= 1
	if should_emit:
		_recent_frame_traces.append(trace.duplicate(true))
		var max_recent_traces: int = maxi(_config.recent_frame_trace_count, 0)
		if max_recent_traces > 0 and _recent_frame_traces.size() > max_recent_traces:
			_recent_frame_traces = _recent_frame_traces.slice(_recent_frame_traces.size() - max_recent_traces)
		elif max_recent_traces == 0:
			_recent_frame_traces.clear()
		frame_trace_recorded.emit(trace.duplicate(true))
		return trace
	return {}
