extends Node

const MetricsModuleScript = preload("src/metrics_module.gd")
const MetricsLiveServerScript = preload("src/metrics_live_server.gd")
const MetricsRuntimeSamplerScript = preload("src/metrics_runtime_sampler.gd")

var _collector: RefCounted = MetricsModuleScript.new()
var _live_server: Node = null
var _runtime_sampler: RefCounted = MetricsRuntimeSamplerScript.new()

func configure(config: RefCounted) -> void:
	_collector.configure(config)

func is_enabled() -> bool:
	return _collector.is_enabled()

func begin_timer() -> int:
	return _collector.begin_timer()

func push_context(tags: Dictionary) -> Dictionary[String, Variant]:
	return _collector.push_context(tags)

func pop_context() -> Dictionary[String, Variant]:
	return _collector.pop_context()

func clear_context() -> void:
	_collector.clear_context()

func set_context(tags: Dictionary) -> void:
	_collector.set_context(tags)

func context_tags(extra_tags: Dictionary = {}) -> Dictionary[String, Variant]:
	return _collector.context_tags(extra_tags)

func begin_span(path: String, tags: Dictionary = {}) -> RefCounted:
	return _collector.begin_span(path, tags)

func record_timer(path: String, duration_usec: int, tags: Dictionary = {}) -> void:
	_collector.record_timer(path, duration_usec, tags)

func finish_timer(path: String, start_time_usec: int, tags: Dictionary = {}) -> void:
	_collector.finish_timer(path, start_time_usec, tags)

func finish_and_return(path: String, start_time_usec: int, value: Variant, tags: Dictionary = {}) -> Variant:
	return _collector.finish_and_return(path, start_time_usec, value, tags)

func set_gauge(path: String, value: float, unit: String = "value", tags: Dictionary = {}) -> void:
	_collector.set_gauge(path, value, unit, tags)

func increment_counter(path: String, amount: float = 1.0, unit: String = "count", tags: Dictionary = {}) -> void:
	_collector.increment_counter(path, amount, unit, tags)

func log(level: String, message: String, tags: Dictionary = {}, fields: Dictionary = {}) -> Dictionary[String, Variant]:
	return _collector.log(level, message, tags, fields)

func event(name: String, tags: Dictionary = {}, fields: Dictionary = {}) -> Dictionary[String, Variant]:
	return _collector.event(name, tags, fields)

func capture_trace_frames(frame_count: int) -> void:
	_collector.capture_trace_frames(frame_count)

func checkpoint_runtime(name: String, tags: Dictionary = {}) -> Dictionary[String, Variant]:
	var runtime_snapshot: Dictionary = _runtime_sampler.sample(0.0)
	return _collector.checkpoint_runtime(name, runtime_snapshot, tags)

func get_timer_summary(path: String, tags: Dictionary = {}) -> Dictionary[String, Variant]:
	return _collector.get_timer_summary(path, tags)

func export_metrics(include_raw_samples: bool = false) -> Array[Dictionary]:
	return _collector.export_metrics(include_raw_samples)

func export_metrics_filtered(options: Dictionary = {}) -> Array[Dictionary]:
	return _collector.export_metrics_filtered(options)

func export_snapshot(include_raw_samples: bool = false) -> Dictionary[String, Variant]:
	var snapshot: Dictionary[String, Variant] = _collector.export_snapshot(include_raw_samples)
	snapshot["runtime"] = _runtime_sampler.get_last_snapshot()
	return snapshot

func export_snapshot_filtered(options: Dictionary = {}) -> Dictionary[String, Variant]:
	var snapshot: Dictionary[String, Variant] = _collector.export_snapshot_filtered(options)
	if bool(options.get("include_runtime", true)):
		var runtime_snapshot: Dictionary = _runtime_sampler.get_last_snapshot()
		if runtime_snapshot.is_empty():
			runtime_snapshot = _runtime_sampler.sample(0.0)
		snapshot["runtime"] = runtime_snapshot
	return snapshot

func build_summary(options: Dictionary = {}) -> Dictionary[String, Variant]:
	return _collector.build_summary([], options)

func diagnose_metrics() -> Array[String]:
	return _collector.diagnose()

func reset(path: String = "", tags: Dictionary = {}) -> void:
	_collector.reset(path, tags)

func clear() -> void:
	_collector.clear()

func start_live_server(config: RefCounted = null) -> Error:
	stop_live_server()
	_live_server = MetricsLiveServerScript.new()
	add_child(_live_server)
	return _live_server.start_server(_collector, config, _runtime_sampler)

func stop_live_server() -> void:
	if _live_server != null and is_instance_valid(_live_server):
		_live_server.stop()
		_live_server.queue_free()
	_live_server = null

func get_live_server_url() -> String:
	if _live_server == null or not is_instance_valid(_live_server):
		return ""
	return _live_server.get_url()
