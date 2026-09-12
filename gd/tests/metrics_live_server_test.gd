extends SceneTree

const MetricsModule = preload("res://addon/src/metrics_module.gd")
const MetricsLiveServer = preload("res://addon/src/metrics_live_server.gd")

class FakeRuntimeSampler extends RefCounted:
	var sample_count: int = 0
	var snapshot: Dictionary = {}
	func sample(_delta: float = 0.0) -> Dictionary:
		sample_count += 1
		snapshot = {"sample_count": sample_count}
		return snapshot.duplicate(true)
	func get_last_snapshot() -> Dictionary:
		return snapshot.duplicate(true)

func _initialize() -> void:
	var failures: Array[String] = []
	await _test_start_stop_and_snapshot(failures)
	_test_sampling_cadence_and_timer_semantics(failures)
	await _test_non_loopback_auth_and_allowlist(failures)
	await _test_slow_client_disconnect(failures)

	if failures.is_empty():
		print("PASS gd-observe metrics_live_server_test")
		quit(0)
		return

	for failure in failures:
		push_error(failure)
	quit(1)

func _test_start_stop_and_snapshot(failures: Array[String]) -> void:
	var metrics := MetricsModule.new()
	metrics.configure(MetricsModule.MetricsConfig.new(true, 10))
	metrics.record_timer("Svc.latency", 42)
	var server := MetricsLiveServer.new()
	root.add_child(server)
	var config := MetricsLiveServer.MetricsLiveServerConfig.new(true, "127.0.0.1", 0, 50, false)
	var error: Error = server.start_server(metrics, config)
	if error != OK:
		failures.append("live_server: expected start OK, got %s" % error)
		server.queue_free()
		return
	if not server.is_running():
		failures.append("live_server: expected server to be running")
	if server.get_port() <= 0:
		failures.append("live_server: expected assigned local port")
	if not server.get_url().begins_with("ws://127.0.0.1:"):
		failures.append("live_server: expected localhost websocket URL")
	await _assert_client_receives_stream(server, metrics, failures)
	server.stop()
	if server.is_running():
		failures.append("live_server: expected server to stop")
	server.queue_free()

func _assert_client_receives_stream(server: MetricsLiveServer, metrics: MetricsModule, failures: Array[String]) -> void:
	var client := WebSocketPeer.new()
	var error: Error = client.connect_to_url(server.get_url())
	if error != OK:
		failures.append("live_server: expected client connect OK, got %s" % error)
		return
	var saw_hello: bool = false
	var saw_snapshot: bool = false
	var saw_log: bool = false
	var saw_event: bool = false
	var saw_trace: bool = false
	var emitted_stream_entries: bool = false
	for _i in 120:
		server._process(0.016)
		await process_frame
		client.poll()
		server._process(0.016)
		if saw_snapshot and not emitted_stream_entries:
			emitted_stream_entries = true
			metrics.log("info", "client connected", {"test": "live"}, {})
			metrics.event("test.stream_ready", {"test": "live"}, {})
			metrics.record_timer("Svc.stream_span", 99)
			server._process(0.016)
		while client.get_available_packet_count() > 0:
			var payload: String = client.get_packet().get_string_from_utf8()
			var parsed: Variant = JSON.parse_string(payload)
			if not (parsed is Dictionary):
				continue
			var message: Dictionary = parsed
			var message_type: String = str(message.get("type", ""))
			if message_type == "hello":
				saw_hello = true
			elif message_type == "snapshot":
				saw_snapshot = true
				if int(message.get("metric_count", 0)) != 1:
					failures.append("live_server: expected snapshot metric_count=1")
				if int(message.get("timer_count", 0)) != 1:
					failures.append("live_server: expected snapshot timer_count=1")
				if not message.has("runtime"):
					failures.append("live_server: expected runtime snapshot")
			elif message_type == "log":
				saw_log = true
			elif message_type == "event" and str(message.get("name", "")) == "test.stream_ready":
				saw_event = true
			elif message_type == "frame_trace":
				saw_trace = true
		if saw_hello and saw_snapshot and saw_log and saw_event and saw_trace:
			client.close()
			return
	failures.append("live_server: expected hello, snapshot, log, event, and frame_trace messages")
	client.close()

func _test_sampling_cadence_and_timer_semantics(failures: Array[String]) -> void:
	var metrics := MetricsModule.new()
	var sampler := FakeRuntimeSampler.new()
	var server := MetricsLiveServer.new()
	root.add_child(server)
	var disabled_periodic := MetricsLiveServer.MetricsLiveServerConfig.new(true, "127.0.0.1", 0, 0)
	if server.start_server(metrics, disabled_periodic, sampler) != OK:
		failures.append("cadence: expected zero-interval server start")
	else:
		for _frame in 20:
			server._process(0.016)
		if sampler.sample_count != 0:
			failures.append("cadence: zero interval must not sample per frame")
	server.stop()
	var cadence := MetricsLiveServer.MetricsLiveServerConfig.new(true, "127.0.0.1", 0, 250)
	server.start_server(metrics, cadence, sampler)
	server._process(0.016)
	var first_count: int = sampler.sample_count
	for _frame in 20:
		server._process(0.016)
	if sampler.sample_count != first_count:
		failures.append("cadence: runtime monitor sampled again before 250ms elapsed")
	server.stop()
	server.queue_free()

func _test_non_loopback_auth_and_allowlist(failures: Array[String]) -> void:
	var metrics := MetricsModule.new()
	metrics.configure(MetricsModule.MetricsConfig.new(true, 10))
	var denied := MetricsLiveServer.new()
	root.add_child(denied)
	var denied_config := MetricsLiveServer.MetricsLiveServerConfig.new(true, "0.0.0.0", 0)
	if denied.start_server(metrics, denied_config) != ERR_UNAUTHORIZED:
		failures.append("auth: non-loopback must reject without explicit opt-in and token")
	denied.queue_free()

	var server := MetricsLiveServer.new()
	root.add_child(server)
	var config := MetricsLiveServer.MetricsLiveServerConfig.new(true, "0.0.0.0", 0, 0, false, true, false, 900000, 1048576, true, "test-only-token", 5000, PackedStringArray(["safe"]), PackedStringArray(["safe"]))
	if server.start_server(metrics, config) != OK:
		failures.append("auth: opted-in non-loopback server failed to start")
		server.queue_free()
		return
	var client := WebSocketPeer.new()
	client.connect_to_url("ws://127.0.0.1:%d" % server.get_port())
	var authenticated: bool = false
	var emitted_payload: bool = false
	for frame in 120:
		server._process(0.016)
		await process_frame
		client.poll()
		if client.get_ready_state() == WebSocketPeer.STATE_OPEN and not authenticated:
			metrics.log("info", "preauth", {"safe": "no"}, {"safe": 0})
			server._process(0.016)
			await process_frame
			client.poll()
			if client.get_available_packet_count() != 0:
				failures.append("auth: server emitted data before authentication")
			client.send_text(JSON.stringify({"type": "auth", "token": "test-only-token"}))
			authenticated = true
		server._process(0.016)
		while client.get_available_packet_count() > 0:
			var text := client.get_packet().get_string_from_utf8()
			if text.contains("must-not-leave") or text.contains("authorization") or text.contains("\"token\""):
				failures.append("auth: non-allowlisted game payload escaped")
				client.close()
				server.stop()
				server.queue_free()
				return
			if text.contains("\"type\":\"hello\"") and not emitted_payload:
				emitted_payload = true
				metrics.log("info", "payload", {"safe": "yes", "token": "must-not-leave"}, {"safe": 1, "authorization": "must-not-leave"})
				server._process(0.016)
			elif text.contains("\"type\":\"log\"") and text.contains("\"safe\""):
				client.close()
				server.stop()
				server.queue_free()
				return
	failures.append("auth: authenticated client did not receive sanitized payload")
	client.close()
	server.stop()
	server.queue_free()

func _test_slow_client_disconnect(failures: Array[String]) -> void:
	var metrics := MetricsModule.new()
	metrics.configure(MetricsModule.MetricsConfig.new(true, 10))
	metrics.record_timer("large", 1, {"value": "x".repeat(100)})
	var server := MetricsLiveServer.new()
	root.add_child(server)
	var config := MetricsLiveServer.MetricsLiveServerConfig.new(true, "127.0.0.1", 0, 50, true, true, true, 900000, 0)
	server.start_server(metrics, config)
	server._config.max_client_buffer_bytes = 1048576
	if server._is_slow_client(1048575) or not server._is_slow_client(1048576):
		failures.append("slow client: expected exact 1 MiB threshold")
	server._config.max_client_buffer_bytes = 0
	var client := WebSocketPeer.new()
	client.connect_to_url(server.get_url())
	for _frame in 120:
		server._process(0.016)
		await process_frame
		client.poll()
		var counters: Dictionary = server.get_transport_counters()
		if int(counters.get("slow_client_disconnects", 0)) > 0:
			client.close()
			server.stop()
			server.queue_free()
			return
	failures.append("slow client: expected strict outbound buffer disconnect")
	client.close()
	server.stop()
	server.queue_free()
