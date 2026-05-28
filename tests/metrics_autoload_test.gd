extends SceneTree

const MetricsAutoload = preload("res://addon/autoload.gd")
const MetricsModule = preload("res://addon/src/metrics_module.gd")
const MetricsLiveServer = preload("res://addon/src/metrics_live_server.gd")

func _initialize() -> void:
	var failures: Array[String] = []
	_test_autoload_facade(failures)

	if failures.is_empty():
		print("PASS gd-metrics metrics_autoload_test")
		quit(0)
		return

	for failure in failures:
		push_error(failure)
	quit(1)

func _test_autoload_facade(failures: Array[String]) -> void:
	var autoload := MetricsAutoload.new()
	root.add_child(autoload)
	autoload.configure(MetricsModule.MetricsConfig.new(true, 10))
	var timer: int = autoload.begin_timer()
	autoload.finish_timer("Autoload.timer", timer)
	autoload.set_gauge("Autoload.gauge", 2, "value", {"scope": "test"})
	autoload.increment_counter("Autoload.counter", 3, "count", {"scope": "test"})
	var log_entry: Dictionary = autoload.log("info", "autoload ready", {"scope": "test"}, {})
	var event_entry: Dictionary = autoload.event("autoload.ready", {"scope": "test"}, {})
	var snapshot: Dictionary[String, Variant] = autoload.export_snapshot(false)
	if int(snapshot.get("metric_count", 0)) != 3:
		failures.append("autoload: expected metric_count=3")
	if log_entry.is_empty() or event_entry.is_empty():
		failures.append("autoload: expected log and event facade entries")
	var config := MetricsLiveServer.MetricsLiveServerConfig.new(false)
	var error: Error = autoload.start_live_server(config)
	if error != OK:
		failures.append("autoload: expected disabled live server start OK")
	autoload.stop_live_server()
	autoload.queue_free()
