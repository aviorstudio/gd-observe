extends SceneTree

const MetricsRuntimeSampler = preload("res://addon/src/metrics_runtime_sampler.gd")

func _initialize() -> void:
	var failures: Array[String] = []
	_test_runtime_snapshot_shape(failures)

	if failures.is_empty():
		print("PASS gd-observe metrics_runtime_sampler_test")
		quit(0)
		return

	for failure in failures:
		push_error(failure)
	quit(1)

func _test_runtime_snapshot_shape(failures: Array[String]) -> void:
	var sampler := MetricsRuntimeSampler.new()
	var snapshot: Dictionary[String, Variant] = sampler.sample(0.016)
	for key in [
		"timestamp_usec",
		"sample_count",
		"fps",
		"frame_delta_usec",
		"process_time_usec",
		"physics_process_time_usec",
		"memory_static_bytes",
		"object_count",
		"node_count",
		"draw_calls_in_frame",
		"video_memory_bytes",
	]:
		if not snapshot.has(key):
			failures.append("runtime_sampler: missing key %s" % key)
	if int(snapshot.get("sample_count", 0)) != 1:
		failures.append("runtime_sampler: expected sample_count=1")
	if int(snapshot.get("frame_delta_usec", 0)) != 16000:
		failures.append("runtime_sampler: expected 16ms frame delta")
