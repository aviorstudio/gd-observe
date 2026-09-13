extends SceneTree

const MetricsModule = preload("res://addon/src/metrics_module.gd")
const MetricsLiveServer = preload("res://addon/src/metrics_live_server.gd")
const ObserveConfig = preload("res://addon/src/observe_config.gd")
const ObserveLiveServerConfig = preload("res://addon/src/observe_live_server_config.gd")

func _initialize() -> void:
	var failures: Array[String] = []
	_test_observe_config_converts_to_runtime_config(failures)
	_test_live_server_config_converts_to_runtime_config(failures)

	if failures.is_empty():
		print("PASS gd-observe observe_resources_test")
		quit(0)
		return

	for failure in failures:
		push_error(failure)
	quit(1)

func _test_observe_config_converts_to_runtime_config(failures: Array[String]) -> void:
	var resource := ObserveConfig.new()
	resource.enabled = false
	resource.max_timer_samples = 42
	resource.trace_enabled = false
	resource.trace_continuous_enabled = false
	resource.trace_slow_frame_threshold_usec = 1234
	resource.recent_frame_trace_count = 17
	var config: MetricsModule.MetricsConfig = resource.to_metrics_config()
	if config.enabled:
		failures.append("ObserveConfig: expected enabled=false")
	if config.max_timer_samples != 42:
		failures.append("ObserveConfig: expected max_timer_samples=42")
	if config.trace_enabled or config.trace_continuous_enabled:
		failures.append("ObserveConfig: expected trace flags to convert")
	if config.trace_slow_frame_threshold_usec != 1234:
		failures.append("ObserveConfig: expected slow frame threshold to convert")
	if config.recent_frame_trace_count != 17:
		failures.append("ObserveConfig: expected recent frame count to convert")

func _test_live_server_config_converts_to_runtime_config(failures: Array[String]) -> void:
	var resource := ObserveLiveServerConfig.new()
	resource.enabled = true
	resource.host = "127.0.0.1"
	resource.port = 9999
	resource.snapshot_interval_msec = 333
	resource.include_raw_samples = true
	resource.include_runtime_stats = false
	resource.include_frame_traces = true
	resource.max_snapshot_bytes = 123456
	resource.max_client_buffer_bytes = 1048576
	resource.allow_non_loopback = true
	resource.auth_timeout_msec = 5000
	resource.allowed_tag_keys = PackedStringArray(["route"])
	resource.allowed_field_keys = PackedStringArray(["count"])
	var overrides := {"port": 7777, "auth_token": "runtime-only-test-token"}
	var config: MetricsLiveServer.MetricsLiveServerConfig = resource.to_live_server_config(overrides)
	if not config.enabled:
		failures.append("ObserveLiveServerConfig: expected enabled=true")
	if config.host != "127.0.0.1":
		failures.append("ObserveLiveServerConfig: expected host conversion")
	if config.port != 7777:
		failures.append("ObserveLiveServerConfig: expected env override port")
	if config.snapshot_interval_msec != 333:
		failures.append("ObserveLiveServerConfig: expected snapshot interval conversion")
	if not config.include_raw_samples or config.include_runtime_stats or not config.include_frame_traces:
		failures.append("ObserveLiveServerConfig: expected boolean flags to convert")
	if config.max_snapshot_bytes != 123456:
		failures.append("ObserveLiveServerConfig: expected max snapshot bytes conversion")
	if config.max_client_buffer_bytes != 1048576 or not config.allow_non_loopback:
		failures.append("ObserveLiveServerConfig: expected slow-client/non-loopback bounds")
	if config.auth_token != "runtime-only-test-token" or config.auth_timeout_msec != 5000:
		failures.append("ObserveLiveServerConfig: expected runtime auth conversion")
	if config.allowed_tag_keys != PackedStringArray(["route"]) or config.allowed_field_keys != PackedStringArray(["count"]):
		failures.append("ObserveLiveServerConfig: expected exact payload allowlists")
