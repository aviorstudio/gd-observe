extends SceneTree

const MetricsModule = preload("res://addon/src/metrics_module.gd")

func _initialize() -> void:
	var failures: Array[String] = []
	_test_timer_summary_percentiles_and_trim(failures)
	_test_gauge_counter_and_reset(failures)
	_test_enabled_and_finish_and_return(failures)
	_test_export_snapshot(failures)
	_test_tags_logs_events_and_traces(failures)
	_test_context_spans_filters_and_runtime_checkpoints(failures)
	_test_export_to_file(failures)

	if failures.is_empty():
		print("PASS gd-observe metrics_module_test")
		quit(0)
		return

	for failure in failures:
		push_error(failure)
	quit(1)

func _test_timer_summary_percentiles_and_trim(failures: Array[String]) -> void:
	var metrics := MetricsModule.new()
	metrics.configure(MetricsModule.MetricsConfig.new(true, 5))

	for value in [10, 20, 30, 40, 50, 60]:
		metrics.record_timer("Svc.latency", value)

	var summary: Dictionary[String, Variant] = metrics.get_timer_summary("Svc.latency")
	if int(summary.get("count", 0)) != 5:
		failures.append("Expected timer count=5 after max-sample trim")
	if int(summary.get("min", 0)) != 20:
		failures.append("Expected min=20 after trimming oldest sample")
	if int(summary.get("max", 0)) != 60:
		failures.append("Expected max=60")
	if int(summary.get("total", 0)) != 200:
		failures.append("Expected total=200")
	if not is_equal_approx(float(summary.get("avg", 0.0)), 40.0):
		failures.append("Expected avg=40.0")
	if int(summary.get("p50", 0)) != 40:
		failures.append("Expected p50=40")
	if int(summary.get("p95", 0)) != 60:
		failures.append("Expected p95=60")
	if int(summary.get("p99", 0)) != 60:
		failures.append("Expected p99=60")
	if int(summary.get("latest", 0)) != 60:
		failures.append("Expected latest=60")

func _test_gauge_counter_and_reset(failures: Array[String]) -> void:
	var metrics := MetricsModule.new()
	metrics.configure(MetricsModule.MetricsConfig.new(true, 10))
	metrics.set_gauge("Runtime.nodes", 12)
	metrics.set_gauge("Runtime.nodes", 15)
	metrics.increment_counter("ObjectPool.unit.created")
	metrics.increment_counter("ObjectPool.unit.created", 2)

	var exported: Array[Dictionary] = metrics.export_metrics()
	var gauge := _find_metric(exported, "Runtime.nodes")
	var counter := _find_metric(exported, "ObjectPool.unit.created")
	if gauge.is_empty() or str(gauge.get("kind", "")) != MetricsModule.KIND_GAUGE:
		failures.append("Expected Runtime.nodes gauge")
	if float(gauge.get("latest", 0.0)) != 15.0:
		failures.append("Expected latest gauge value=15")
	if counter.is_empty() or str(counter.get("kind", "")) != MetricsModule.KIND_COUNTER:
		failures.append("Expected ObjectPool counter")
	if float(counter.get("value", 0.0)) != 3.0:
		failures.append("Expected counter value=3")

	metrics.reset("Runtime.nodes")
	if not _find_metric(metrics.export_metrics(), "Runtime.nodes").is_empty():
		failures.append("Expected reset(path) to remove one metric")
	if _find_metric(metrics.export_metrics(), "ObjectPool.unit.created").is_empty():
		failures.append("Expected reset(path) to keep other metrics")
	metrics.reset()
	if not metrics.export_metrics().is_empty():
		failures.append("Expected reset() to clear all metrics")

func _test_enabled_and_finish_and_return(failures: Array[String]) -> void:
	var metrics := MetricsModule.new()
	metrics.configure(MetricsModule.MetricsConfig.new(false, 10))
	if metrics.is_enabled():
		failures.append("Expected is_enabled() to reflect disabled configuration")
	if metrics.begin_timer() != -1:
		failures.append("Expected begin_timer() to return -1 when disabled")

	metrics.configure(MetricsModule.MetricsConfig.new(true, 10))
	var start_time_usec: int = metrics.begin_timer()
	var value: String = str(metrics.finish_and_return("Svc.pass_through", start_time_usec, "ok"))
	if value != "ok":
		failures.append("Expected finish_and_return() to return the original value")
	if int(metrics.get_timer_summary("Svc.pass_through").get("count", 0)) != 1:
		failures.append("Expected finish_and_return() to record a timer sample")

func _test_export_snapshot(failures: Array[String]) -> void:
	var metrics := MetricsModule.new()
	metrics.configure(MetricsModule.MetricsConfig.new(true, 60))
	metrics.record_timer("SvcA.latency", 100)
	metrics.record_timer("SvcA.latency", 300)
	metrics.set_gauge("Runtime.nodes", 20)
	metrics.increment_counter("ObjectPool.created", 2)
	var snapshot: Dictionary[String, Variant] = metrics.export_snapshot(false)
	if int(snapshot.get("version", 0)) != 2:
		failures.append("snapshot: expected version=2")
	if int(snapshot.get("metric_count", 0)) != 3:
		failures.append("snapshot: expected metric_count=3")
	if int(snapshot.get("timer_count", 0)) != 1:
		failures.append("snapshot: expected timer_count=1")
	if int(snapshot.get("gauge_count", 0)) != 1:
		failures.append("snapshot: expected gauge_count=1")
	if int(snapshot.get("counter_count", 0)) != 1:
		failures.append("snapshot: expected counter_count=1")
	if int(snapshot.get("sample_count", 0)) != 2:
		failures.append("snapshot: expected sample_count=2")
	var metrics_rows: Array = snapshot.get("metrics", [])
	var timer := _find_metric(metrics_rows, "SvcA.latency")
	if timer.has("samples"):
		failures.append("snapshot: raw samples should be omitted by default")
	var raw_snapshot: Dictionary[String, Variant] = metrics.export_snapshot(true)
	var raw_timer := _find_metric(raw_snapshot.get("metrics", []), "SvcA.latency")
	if not raw_timer.has("samples"):
		failures.append("snapshot: expected raw samples when requested")

func _test_tags_logs_events_and_traces(failures: Array[String]) -> void:
	var metrics := MetricsModule.new()
	metrics.configure(MetricsModule.MetricsConfig.new(true, 60, true, true, 1000))
	var logs: Array[Dictionary] = []
	var events: Array[Dictionary] = []
	var traces: Array[Dictionary] = []
	metrics.log_recorded.connect(func(entry: Dictionary) -> void: logs.append(entry))
	metrics.event_recorded.connect(func(entry: Dictionary) -> void: events.append(entry))
	metrics.frame_trace_recorded.connect(func(trace: Dictionary) -> void: traces.append(trace))

	metrics.record_timer("Svc.tagged", 25, {"phase": "setup"})
	metrics.record_timer("Svc.tagged", 75, {"phase": "render"})
	var setup_summary: Dictionary = metrics.get_timer_summary("Svc.tagged", {"phase": "setup"})
	var render_summary: Dictionary = metrics.get_timer_summary("Svc.tagged", {"phase": "render"})
	if int(setup_summary.get("latest", 0)) != 25:
		failures.append("tags: expected setup timer to retain independent sample")
	if int(render_summary.get("latest", 0)) != 75:
		failures.append("tags: expected render timer to retain independent sample")
	if str(render_summary.get("key", "")).find("phase") == -1:
		failures.append("tags: expected metric key to include tag identity")

	var log_entry: Dictionary = metrics.log("warn", "pool exhausted", {"pool": "unit"}, {"available": 0})
	if log_entry.is_empty() or logs.size() != 1:
		failures.append("logs: expected explicit log entry signal")
	elif str(logs[0].get("level", "")) != "warn":
		failures.append("logs: expected normalized warn level")

	var event_entry: Dictionary = metrics.event("match route loaded", {"route": "match"}, {"id": "abc"})
	if event_entry.is_empty() or events.size() != 1:
		failures.append("events: expected explicit event entry signal")
	elif str(events[0].get("name", "")) != "match_route_loaded":
		failures.append("events: expected normalized event name")

	var trace: Dictionary = metrics.flush_frame_trace()
	if trace.is_empty() or traces.size() != 1:
		failures.append("traces: expected timer samples to emit a frame trace")
	elif int(trace.get("span_count", 0)) < 2:
		failures.append("traces: expected timer samples to become spans")
	var snapshot: Dictionary = metrics.export_snapshot(false)
	if Array(snapshot.get("recent_frame_traces", [])).is_empty():
		failures.append("traces: expected snapshot to include recent frame traces")

func _test_context_spans_filters_and_runtime_checkpoints(failures: Array[String]) -> void:
	var metrics := MetricsModule.new()
	metrics.configure(MetricsModule.MetricsConfig.new(true, 60))
	metrics.push_context({"route": "match"})
	metrics.record_timer("Svc.contextual", 100, {"phase": "start"})
	var contextual: Dictionary = metrics.get_timer_summary("Svc.contextual", {"route": "match", "phase": "start"})
	if contextual.is_empty():
		failures.append("context: expected pushed context tags to apply to timers")
	var span: RefCounted = metrics.begin_span("Svc.span", {"kind": "test"})
	span.checkpoint("halfway")
	span.finish({"result": "ok"})
	if metrics.get_timer_summary("Svc.span", {"route": "match", "kind": "test", "result": "ok"}).is_empty():
		failures.append("span: expected finish to record timer with context")
	metrics.checkpoint_runtime("start", {"node_count": 10, "memory_static_bytes": 100}, {})
	metrics.checkpoint_runtime("end", {"node_count": 14, "memory_static_bytes": 150}, {})
	var filtered: Array[Dictionary] = metrics.export_metrics_filtered({"kind": MetricsModule.KIND_TIMER, "path_prefix": "Svc.", "limit": 2, "sort": "p95"})
	if filtered.size() != 2:
		failures.append("filters: expected limited filtered timer export")
	var snapshot: Dictionary = metrics.export_snapshot_filtered({"include_traces": false})
	if not Array(snapshot.get("recent_frame_traces", [])).is_empty():
		failures.append("snapshot filters: expected traces to be omitted")
	if not snapshot.has("summary"):
		failures.append("snapshot summary: expected built-in summary")
	if Array(snapshot.get("runtime_deltas", [])).is_empty():
		failures.append("runtime checkpoints: expected runtime deltas")
	metrics.pop_context()

func _test_export_to_file(failures: Array[String]) -> void:
	var metrics := MetricsModule.new()
	metrics.configure(MetricsModule.MetricsConfig.new(true, 60))
	metrics.record_timer("FileSvc.op", 500)
	var test_path: String = "user://test_metrics_export.json"
	var success: bool = metrics.export_to_file(test_path)
	if not success:
		failures.append("export_to_file: expected true return")
		return
	var file := FileAccess.open(test_path, FileAccess.READ)
	if file == null:
		failures.append("export_to_file: file not created")
		return
	var content: String = file.get_as_text()
	file.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(test_path))
	if not content.contains("FileSvc.op"):
		failures.append("export_to_file: expected JSON to contain metric path")

func _find_metric(metrics: Array, path: String) -> Dictionary:
	for metric in metrics:
		if metric is Dictionary and str(metric.get("path", "")) == path:
			return metric
	return {}
