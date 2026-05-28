extends SceneTree

const MetricsModule = preload("res://addon/src/metrics_module.gd")
const MetricsLiveServer = preload("res://addon/src/metrics_live_server.gd")

func _initialize() -> void:
	var failures: Array[String] = []
	await _test_start_stop_and_snapshot(failures)

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
