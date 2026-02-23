extends SceneTree

const MetricsModule = preload("res://src/metrics_module.gd")

func _initialize() -> void:
	var failures: Array[String] = []
	_test_summary_percentiles_and_trim(failures)
	_test_get_all_summaries_and_reset(failures)
	_test_enabled_and_finish_and_return(failures)

	if failures.is_empty():
		print("PASS gd-metrics metrics_module_test")
		quit(0)
		return

	for failure in failures:
		push_error(failure)
	quit(1)

func _test_summary_percentiles_and_trim(failures: Array[String]) -> void:
	var metrics := MetricsModule.new()
	metrics.configure(MetricsModule.MetricsConfig.new(true, 5))

	for value in [10, 20, 30, 40, 50, 60]:
		metrics.record("Svc", "latency", value)

	var summary: MetricsModule.MetricsSummary = metrics.get_summary("Svc", "latency")
	if summary.count != 5:
		failures.append("Expected summary count=5 after max-sample trim")
	if summary.min_usec != 20:
		failures.append("Expected min_usec=20 after trimming oldest sample")
	if summary.max_usec != 60:
		failures.append("Expected max_usec=60")
	if summary.total_usec != 200:
		failures.append("Expected total_usec=200")
	if not is_equal_approx(summary.avg_usec, 40.0):
		failures.append("Expected avg_usec=40.0")
	if summary.p50_usec != 40:
		failures.append("Expected p50_usec=40")
	if summary.p95_usec != 60:
		failures.append("Expected p95_usec=60")
	if summary.p99_usec != 60:
		failures.append("Expected p99_usec=60")

func _test_get_all_summaries_and_reset(failures: Array[String]) -> void:
	var metrics := MetricsModule.new()
	metrics.configure(MetricsModule.MetricsConfig.new(true, 10))
	metrics.record("SvcA", "a", 5)
	metrics.record("SvcA", "a", 15)
	metrics.record("SvcB", "b", 7)

	var all_summaries: Dictionary[String, Dictionary] = metrics.get_all_summaries()
	if not all_summaries.has("SvcA") or not all_summaries.has("SvcB"):
		failures.append("Expected get_all_summaries to include both services")
	else:
		var svc_a_summary: MetricsModule.MetricsSummary = all_summaries["SvcA"].get("a", null)
		if svc_a_summary == null or svc_a_summary.count != 2:
			failures.append("Expected summary object for SvcA/a with count=2")

	metrics.reset("SvcA")
	if metrics.get_summary("SvcA", "a").count != 0:
		failures.append("Expected reset(service) to remove only one service")
	if metrics.get_summary("SvcB", "b").count != 1:
		failures.append("Expected reset(service) to keep other services")

	metrics.reset()
	if not metrics.get_all_summaries().is_empty():
		failures.append("Expected reset() with empty service to clear all metrics")

func _test_enabled_and_finish_and_return(failures: Array[String]) -> void:
	var metrics := MetricsModule.new()
	metrics.configure(MetricsModule.MetricsConfig.new(false, 10))
	if metrics.is_enabled():
		failures.append("Expected is_enabled() to reflect disabled configuration")

	metrics.configure(MetricsModule.MetricsConfig.new(true, 10))
	if not metrics.is_enabled():
		failures.append("Expected is_enabled() to reflect enabled configuration")

	var start_time_usec: int = metrics.begin_timer(true)
	var value: String = str(metrics.finish_and_return(start_time_usec, "Svc", "pass_through", "ok"))
	if value != "ok":
		failures.append("Expected finish_and_return() to return the original value")

	var summary: MetricsModule.MetricsSummary = metrics.get_summary("Svc", "pass_through")
	if summary.count != 1:
		failures.append("Expected finish_and_return() to record a metric sample")
